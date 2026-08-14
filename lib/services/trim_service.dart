import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:image/image.dart';

import '../models/trim_preset.dart';

/// 去白边核心服务
///
/// 所有像素级处理都在静态方法中完成，批量处理提供顶层 isolate 入口。
/// 算法移植自 Windows 版 cmbook 的 trim_image_whitespace / resize_for_zoom。
class TrimService {
  /// 最小内容尺寸（宽或高小于此值的图片视为小图标，跳过处理）
  static const int _minContentSize = 100;

  /// 边界检测跳步步长（每 N 像素采样一次，加速扫描）
  static const int _scanStep = 2;

  /// 对单张图片执行去白边 + 放大
  ///
  /// 返回处理后的图片，若无需处理（无白边且不放大）则返回 null。
  static Image? processImage(Image src, TrimParams params) {
    // 1. 尺寸过滤
    if (src.width < _minContentSize || src.height < _minContentSize) {
      return null;
    }

    // 2. 求内容包围盒
    final bbox = _findContentBbox(src, params.threshold);
    if (bbox == null) return null; // 全白图，无法处理

    int left = bbox.left;
    int top = bbox.top;
    int right = bbox.right;
    int bottom = bbox.bottom;

    // 无白边可裁且不放大 → 不处理
    final bool noCrop = left == 0 &&
        top == 0 &&
        right == src.width &&
        bottom == src.height;
    if (noCrop && params.zoom <= 100) return null;

    // 3. 加 padding 并钳制
    if (params.padding > 0) {
      left = (left - params.padding).clamp(0, src.width);
      top = (top - params.padding).clamp(0, src.height);
      right = (right + params.padding).clamp(0, src.width);
      bottom = (bottom + params.padding).clamp(0, src.height);
    }

    // 4. 裁剪
    Image result = copyCrop(
      src,
      x: left,
      y: top,
      width: right - left,
      height: bottom - top,
    );

    // 5. 放大（zoom > 100 时）
    if (params.zoom > 100 &&
        params.deviceWidth > 0 &&
        params.deviceHeight > 0) {
      final factor = params.zoom / 100.0;
      final maxW = params.deviceWidth.toDouble();
      final maxH = params.deviceHeight.toDouble();

      // 等比夹在设备屏幕内（放大比例和屏幕尺寸取较小者）
      final screenScale =
          (maxW / result.width).clamp(0, maxH / result.height);
      final scale = factor < screenScale ? factor : screenScale;

      if (scale > 1.0) {
        result = copyResize(
          result,
          width: (result.width * scale).round(),
          height: (result.height * scale).round(),
          interpolation: Interpolation.average,
        );
      }
    }

    return result;
  }

  /// 求内容包围盒（手动实现 bbox 检测）
  ///
  /// 灰度模式：亮度 < threshold 视为内容像素
  /// 四向扫描：从上、下、左、右各找第一个有内容像素的行/列
  /// 返回 null 表示全白（找不到内容）
  static _Rect? _findContentBbox(Image img, int threshold) {
    final w = img.width;
    final h = img.height;

    // 提前判断：如果四边都不是白边，就没有白边，直接返回全图 bbox
    if (!_isRowWhite(img, 0, threshold) &&
        !_isRowWhite(img, h - 1, threshold) &&
        !_isColWhite(img, 0, threshold) &&
        !_isColWhite(img, w - 1, threshold)) {
      return _Rect(0, 0, w, h);
    }

    // 上边界：从上往下扫
    int top = 0;
    for (int y = 0; y < h; y += _scanStep) {
      if (!_isRowWhite(img, y, threshold)) {
        top = y;
        break;
      }
    }
    // 精细修正（往回扫 _scanStep 行找到精确边界）
    for (int y = top; y > 0 && y > top - _scanStep; y--) {
      if (_isRowWhite(img, y - 1, threshold)) {
        top = y;
        break;
      }
    }

    // 下边界：从下往上扫
    int bottom = h - 1;
    for (int y = h - 1; y >= 0; y -= _scanStep) {
      if (!_isRowWhite(img, y, threshold)) {
        bottom = y;
        break;
      }
    }
    for (int y = bottom; y < h - 1 && y < bottom + _scanStep; y++) {
      if (_isRowWhite(img, y + 1, threshold)) {
        bottom = y;
        break;
      }
    }

    // 左边界：从左往右扫
    int left = 0;
    for (int x = 0; x < w; x += _scanStep) {
      if (!_isColWhite(img, x, threshold)) {
        left = x;
        break;
      }
    }
    for (int x = left; x > 0 && x > left - _scanStep; x--) {
      if (_isColWhite(img, x - 1, threshold)) {
        left = x;
        break;
      }
    }

    // 右边界：从右往左扫
    int right = w - 1;
    for (int x = w - 1; x >= 0; x -= _scanStep) {
      if (!_isColWhite(img, x, threshold)) {
        right = x;
        break;
      }
    }
    for (int x = right; x < w - 1 && x < right + _scanStep; x++) {
      if (_isColWhite(img, x + 1, threshold)) {
        right = x;
        break;
      }
    }

    // 边界有效则返回（right > left 且 bottom > top）
    if (right <= left || bottom <= top) return null;
    return _Rect(left, top, right + 1, bottom + 1);
  }

  /// 判断某一行是否全是白边（所有像素亮度 >= threshold）
  static bool _isRowWhite(Image img, int y, int threshold) {
    final w = img.width;
    for (int x = 0; x < w; x += _scanStep) {
      final pixel = img.getPixel(x, y);
      // 计算亮度（加权平均，人眼对绿色敏感）
      final l = pixel.r * 0.299 + pixel.g * 0.587 + pixel.b * 0.114;
      if (l < threshold) return false; // 有内容像素
    }
    return true;
  }

  /// 判断某一列是否全是白边
  static bool _isColWhite(Image img, int x, int threshold) {
    final h = img.height;
    for (int y = 0; y < h; y += _scanStep) {
      final pixel = img.getPixel(x, y);
      final l = pixel.r * 0.299 + pixel.g * 0.587 + pixel.b * 0.114;
      if (l < threshold) return false;
    }
    return true;
  }
}

/// 简单矩形辅助类（左闭右开）
class _Rect {
  final int left;
  final int top;
  final int right;
  final int bottom;
  const _Rect(this.left, this.top, this.right, this.bottom);
}

// ============================================================
// 顶层 isolate 入口
// ============================================================

/// Isolate 请求参数
class _TrimDirectoryRequest {
  final String dirPath;
  final TrimParams params;
  const _TrimDirectoryRequest(this.dirPath, this.params);
}

/// 在 worker isolate 中批量处理目录下所有 jpg 图片
///
/// 返回实际处理（写回文件）的图片数量。
/// 单张处理失败时保留原图，记日志，不中断整批。
Future<int> trimDirectoryInIsolate(_TrimDirectoryRequest req) async {
  return _processDirectory(req.dirPath, req.params);
}

/// 公共入口：处理目录（供 compute 调用的顶层函数）
Future<int> processTrimDirectory(String dirPath, TrimParams params) async {
  return _processDirectory(dirPath, params);
}

Future<int> _processDirectory(String dirPath, TrimParams params) async {
  final dir = Directory(dirPath);
  if (!await dir.exists()) return 0;

  final entities = await dir.list().toList();
  // 只处理 jpg/jpeg/png，按文件名排序
  final imageFiles = entities
      .whereType<File>()
      .where((f) {
        final name = f.path.toLowerCase();
        return name.endsWith('.jpg') ||
            name.endsWith('.jpeg') ||
            name.endsWith('.png');
      })
      .toList()
    ..sort((a, b) => a.path.compareTo(b.path));

  if (imageFiles.isEmpty) return 0;

  int processed = 0;
  for (final file in imageFiles) {
    try {
      final bytes = await file.readAsBytes();
      final src = decodeImage(bytes);
      if (src == null) continue;

      final result = TrimService.processImage(src, params);
      if (result == null) continue; // 无需处理

      // 写回（JPEG 90 质量）
      final outBytes = encodeJpg(result, quality: 90);
      await file.writeAsBytes(outBytes);
      processed++;
    } catch (e) {
      if (kDebugMode) {
        debugPrint('[TrimService] 处理失败 ${file.path}: $e');
      }
      // 失败保留原图，不中断
    }
  }

  return processed;
}

/// 预览处理：对单张图片字节做去白边，返回处理后的字节（供 isolate 调用）
Uint8List? trimPreviewImage(Uint8List bytes, TrimParams params) {
  try {
    final src = decodeImage(bytes);
    if (src == null) return null;
    final result = TrimService.processImage(src, params);
    if (result == null) return bytes; // 无变化则返回原图
    return encodeJpg(result, quality: 90);
  } catch (e) {
    if (kDebugMode) {
      debugPrint('[TrimService] 预览处理失败: $e');
    }
    return null;
  }
}
