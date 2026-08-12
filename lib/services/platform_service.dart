import 'package:flutter/services.dart';

/// 平台原生能力（方法通道）：打开目录、取 APK 路径、PDF 光栅化
class PlatformService {
  static const _channel = MethodChannel('cmbok/platform');

  /// 音量键事件回调（方向：'up' / 'down'）。阅读器进入时赋值，退出时置 null。
  static void Function(String direction)? onVolumeKey;
  static bool _handlerInstalled = false;

  /// 安装原生->Dart 回调：收到 onVolumeKey 时转发给 [onVolumeKey]。
  static void _ensureHandler() {
    if (_handlerInstalled) return;
    _handlerInstalled = true;
    _channel.setMethodCallHandler((call) async {
      if (call.method == 'onVolumeKey' && call.arguments is String) {
        onVolumeKey?.call(call.arguments as String);
      }
    });
  }

  /// 开/关音量键翻页拦截（Android 原生 Activity 消费音量键）。
  /// 非安卓/原生未实现时静默忽略。
  static Future<void> setVolumeKeyNav(bool enabled) async {
    _ensureHandler();
    try {
      await _channel.invokeMethod<bool>('setVolumeKeyNav', {
        'enabled': enabled,
      });
    } on PlatformException {
      // ignore
    } on MissingPluginException {
      // ignore
    }
  }

  /// 打开目录（Android 文件管理器）。成功返回 true；非安卓/无应用可处理返回 false。
  static Future<bool> openDirectory(String path) async {
    try {
      final r = await _channel.invokeMethod<bool>('openDir', {'path': path});
      return r ?? false;
    } on PlatformException {
      return false;
    } on MissingPluginException {
      return false;
    }
  }

  /// 用系统外部应用打开文件（按 mimeType 选择阅读器）。成功返回 true；
  /// 无可用应用或非安卓返回 false。
  static Future<bool> openFile(String path, String mimeType) async {
    try {
      final r = await _channel.invokeMethod<bool>('openFile', {
        'path': path,
        'mimeType': mimeType,
      });
      return r ?? false;
    } on PlatformException {
      return false;
    } on MissingPluginException {
      return false;
    }
  }

  /// 取本应用 APK 路径（Android）。取不到返回 null。
  static Future<String?> getApkPath() async {
    try {
      return await _channel.invokeMethod<String>('getApkPath');
    } on PlatformException {
      return null;
    } on MissingPluginException {
      return null;
    }
  }

  /// 打开 PDF 取页数与每页像素尺寸（仅度量不渲染，供分页器度量用）。
  /// 非安卓/失败返回 null。
  static Future<({int pageCount, List<({int w, int h})> sizes})?> pdfOpen(
    String path,
  ) async {
    try {
      final r = await _channel.invokeMethod<Map>('pdfOpen', {'path': path});
      if (r == null) return null;
      final pageCount = r['pageCount'] as int;
      final sizesRaw = r['sizes'] as List;
      final sizes = <({int w, int h})>[];
      for (final s in sizesRaw) {
        final m = s as Map;
        sizes.add((w: m['w'] as int, h: m['h'] as int));
      }
      return (pageCount: pageCount, sizes: sizes);
    } on PlatformException {
      return null;
    } on MissingPluginException {
      return null;
    }
  }

  /// 光栅化 PDF 单页为 JPEG 字节（按 targetWidth 缩放）。
  /// 非安卓/失败返回 null。
  static Future<Uint8List?> pdfRenderPage(
    String path,
    int index,
    int targetWidth,
  ) async {
    try {
      final r = await _channel.invokeMethod<dynamic>('pdfRenderPage', {
        'path': path,
        'index': index,
        'targetWidth': targetWidth,
      });
      if (r == null) return null;
      if (r is Uint8List) return r;
      if (r is List) return Uint8List.fromList(r.cast<int>());
      return null;
    } on PlatformException {
      return null;
    } on MissingPluginException {
      return null;
    }
  }
}
