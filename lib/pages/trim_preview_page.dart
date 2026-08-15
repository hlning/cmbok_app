import 'dart:async';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../models/comic.dart';
import '../models/trim_preset.dart';
import '../services/download_service.dart';
import '../services/trim_service.dart';
import '../source/adapter.dart';
import '../source/source_manager.dart';
import '../theme/jelly_theme.dart';
import '../widgets/device_frame_preview.dart';
import '../widgets/trim_preset_dialog.dart';

/// 去白边预览页面
///
/// 用户在下载前可以调节去白边参数，实时预览效果，确认后开始下载。
class TrimPreviewPage extends StatefulWidget {
  final Comic comic;
  final List<ComicChapter> selectedChapters;

  const TrimPreviewPage({
    super.key,
    required this.comic,
    required this.selectedChapters,
  });

  @override
  State<TrimPreviewPage> createState() => _TrimPreviewPageState();
}

class _TrimPreviewPageState extends State<TrimPreviewPage> {
  TrimParams _params = const TrimParams(
    threshold: 220,
    padding: 0,
    zoom: 100,
    deviceWidth: 1080,
    deviceHeight: 1920,
  );
  int _currentIndex = 0;
  final List<Uint8List> _previewOriginals = [];
  Uint8List? _processedBytes;
  bool _isLoading = true;
  bool _isProcessing = false;
  bool _loadError = false;
  String _errorMsg = '';

  Timer? _debounceTimer;
  CancelToken? _cancelToken;

  static const int _previewCount = 5; // 预览图片数量

  @override
  void initState() {
    super.initState();
    // 默认设备分辨率取当前屏幕物理像素
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final mq = MediaQuery.of(context);
      final phyW = (mq.size.width * mq.devicePixelRatio).round();
      final phyH = (mq.size.height * mq.devicePixelRatio).round();
      setState(() {
        _params = TrimParams.defaultWithDevice(phyW, phyH);
      });
      _loadPreviewImages();
    });
  }

  @override
  void dispose() {
    _debounceTimer?.cancel();
    _cancelToken?.cancel();
    super.dispose();
  }

  /// 加载预览图（取第一选中章节的前 N 张图）
  Future<void> _loadPreviewImages() async {
    setState(() {
      _isLoading = true;
      _loadError = false;
      _errorMsg = '';
    });

    try {
      final sourceId = widget.comic.sourceId ?? 'copy_manga';
      final source = SourceManager().getSource(sourceId) ??
          SourceManager().current;
      final cmanga = comicToCManga(widget.comic, sourceId);
      final firstChapter = widget.selectedChapters.first;
      final cchapter = comicChapterToCChapter(
        firstChapter,
        sourceId,
        cmanga.id,
      );

      // 获取图片 URL 列表
      final urls = await source.getChapterImages(cmanga, cchapter);
      if (urls.isEmpty) {
        setState(() {
          _loadError = true;
          _errorMsg = '该章节暂无图片';
          _isLoading = false;
        });
        return;
      }

      // 取前 N 张下载
      final previewUrls = urls.take(_previewCount).toList();
      _cancelToken = CancelToken();
      final headers = <String, dynamic>{...source.imageHeaders};
      final ref = source.refererForChapter(cchapter);
      if (ref != null) headers['Referer'] = ref;

      final dio = Dio();
      final List<Uint8List> loaded = [];
      for (final url in previewUrls) {
        if (_cancelToken?.isCancelled == true) break;
        try {
          final resp = await dio.get(
            url,
            options: Options(
              responseType: ResponseType.bytes,
              headers: headers,
            ),
            cancelToken: _cancelToken,
          );
          if (resp.data is List<int>) {
            loaded.add(Uint8List.fromList(resp.data as List<int>));
          }
        } catch (e) {
          if (_cancelToken?.isCancelled == true) break;
          // 单张失败不中断
          if (kDebugMode) {
            debugPrint('[TrimPreview] 预览图下载失败: $e');
          }
        }
      }

      if (!mounted) return;
      if (_cancelToken?.isCancelled == true) return;

      setState(() {
        _previewOriginals.clear();
        _previewOriginals.addAll(loaded);
        _isLoading = false;
        _currentIndex = 0;
      });

      if (loaded.isNotEmpty) {
        _updatePreview();
      } else {
        setState(() {
          _loadError = true;
          _errorMsg = '预览图加载失败';
        });
      }
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loadError = true;
        _errorMsg = '加载失败: ${e.toString().substring(0, 60)}';
        _isLoading = false;
      });
    }
  }

  /// 防抖触发预览刷新
  void _schedulePreviewUpdate() {
    _debounceTimer?.cancel();
    _debounceTimer = Timer(const Duration(milliseconds: 300), () {
      _updatePreview();
    });
  }

  /// 重新计算当前预览图的去白边结果
  Future<void> _updatePreview() async {
    if (_previewOriginals.isEmpty) return;
    if (_currentIndex >= _previewOriginals.length) return;

    setState(() {
      _isProcessing = true;
    });

    final original = _previewOriginals[_currentIndex];
    final params = _params;

    try {
      final result = await compute(
        _processPreviewInIsolate,
        _PreviewIsolateRequest(original, params),
      );
      if (!mounted) return;
      setState(() {
        _processedBytes = result;
        _isProcessing = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _isProcessing = false;
      });
      if (kDebugMode) {
        debugPrint('[TrimPreview] 处理失败: $e');
      }
    }
  }

  void _prevImage() {
    if (_currentIndex > 0) {
      setState(() {
        _currentIndex--;
      });
      _schedulePreviewUpdate();
    }
  }

  void _nextImage() {
    if (_currentIndex < _previewOriginals.length - 1) {
      setState(() {
        _currentIndex++;
      });
      _schedulePreviewUpdate();
    }
  }

  void _openPresets() {
    showDialog(
      context: context,
      builder: (ctx) => TrimPresetDialog(
        currentParams: _params,
        onLoad: (preset) {
          setState(() {
            _params = preset.params;
          });
          _schedulePreviewUpdate();
        },
      ),
    );
  }

  Future<void> _editResolution() async {
    final wController = TextEditingController(text: '${_params.deviceWidth}');
    final hController = TextEditingController(text: '${_params.deviceHeight}');
    final result = await showDialog<(int, int)>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor:
            Theme.of(ctx).brightness == Brightness.dark
                ? JellyTheme.cardDark
                : Colors.white,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: const Text('设备分辨率'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: wController,
                    keyboardType: TextInputType.number,
                    decoration: const InputDecoration(
                      labelText: '宽度',
                      border: OutlineInputBorder(),
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                const Text('×'),
                const SizedBox(width: 12),
                Expanded(
                  child: TextField(
                    controller: hController,
                    keyboardType: TextInputType.number,
                    decoration: const InputDecoration(
                      labelText: '高度',
                      border: OutlineInputBorder(),
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Text(
              '用于限制放大上限，图片放大后不会超过该尺寸',
              style: TextStyle(fontSize: 12, color: JellyTheme.textSecondary),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () {
              final w = int.tryParse(wController.text.trim()) ?? 0;
              final h = int.tryParse(hController.text.trim()) ?? 0;
              if (w >= 100 && h >= 100) {
                Navigator.of(ctx).pop((w, h));
              }
            },
            child: const Text('确定'),
          ),
        ],
      ),
    );
    if (result != null) {
      setState(() {
        _params = _params.copyWith(
          deviceWidth: result.$1,
          deviceHeight: result.$2,
        );
      });
      _schedulePreviewUpdate();
    }
  }

  void _confirmDownload() {
    DownloadService().downloadChapters(
      widget.comic,
      widget.selectedChapters,
      trimParams: _params,
    );

    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        const SnackBar(
          content: Text('加入下载队列成功，请到下载中查看进度'),
          duration: Duration(seconds: 2),
          behavior: SnackBarBehavior.floating,
        ),
      );
    // 关闭预览页，返回详情页
    Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Scaffold(
      appBar: AppBar(
        title: const Text('去白边预览'),
        actions: [
          IconButton(
            icon: const Icon(Icons.bookmark_border),
            tooltip: '预设管理',
            onPressed: _openPresets,
          ),
        ],
      ),
      body: Column(
        children: [
          // 设备预览区（尽量撑大）
          Expanded(child: _buildPreviewArea(isDark)),
          // 参数调节区
          _buildParamsPanel(isDark),
          // 底部按钮
          _buildFooter(isDark),
        ],
      ),
    );
  }

  Widget _buildPreviewArea(bool isDark) {
    return Container(
      padding: const EdgeInsets.fromLTRB(24, 8, 24, 4),
      child: _loadError
          ? Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.error_outline, color: JellyTheme.error, size: 36),
                  const SizedBox(height: 8),
                  Text(
                    _errorMsg,
                    style: TextStyle(color: JellyTheme.textSecondary),
                  ),
                  const SizedBox(height: 12),
                  FilledButton.icon(
                    onPressed: _loadPreviewImages,
                    icon: const Icon(Icons.refresh, size: 18),
                    label: const Text('重试'),
                  ),
                ],
              ),
            )
          : DeviceFramePreview(
              imageBytes: _processedBytes,
              deviceWidth: _params.deviceWidth,
              deviceHeight: _params.deviceHeight,
              onPrev: _previewOriginals.isEmpty || _currentIndex == 0
                  ? null
                  : _prevImage,
              onNext: _previewOriginals.isEmpty ||
                      _currentIndex == _previewOriginals.length - 1
                  ? null
                  : _nextImage,
              pageIndicator: _previewOriginals.isEmpty
                  ? ''
                  : '${_currentIndex + 1}/${_previewOriginals.length}',
              isLoading: _isLoading || _isProcessing,
            ),
    );
  }

  Widget _buildParamsPanel(bool isDark) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          _buildSliderCard(
            isDark,
            title: '白边阈值',
            value: _params.threshold,
            min: 0,
            max: 255,
            unit: '',
            onChanged: (v) {
              setState(() {
                _params = _params.copyWith(threshold: v.round());
              });
              _schedulePreviewUpdate();
            },
          ),
          const SizedBox(height: 6),
          _buildSliderCard(
            isDark,
            title: '保留边距',
            value: _params.padding,
            min: 0,
            max: 50,
            unit: 'px',
            onChanged: (v) {
              setState(() {
                _params = _params.copyWith(padding: v.round());
              });
              _schedulePreviewUpdate();
            },
          ),
          const SizedBox(height: 6),
          _buildSliderCard(
            isDark,
            title: '图片放大',
            value: _params.zoom,
            min: 100,
            max: 300,
            unit: '%',
            onChanged: (v) {
              setState(() {
                _params = _params.copyWith(zoom: v.round());
              });
              _schedulePreviewUpdate();
            },
          ),
          const SizedBox(height: 6),
          _buildResolutionCard(isDark),
        ],
      ),
    );
  }

  Widget _buildSliderCard(
    bool isDark, {
    required String title,
    required int value,
    required int min,
    required int max,
    required String unit,
    required ValueChanged<double> onChanged,
  }) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 2),
      decoration: BoxDecoration(
        color: isDark ? JellyTheme.cardDark : JellyTheme.cardLight,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        children: [
          SizedBox(
            width: 68,
            child: Text(
              title,
              style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.bold,
                color: isDark ? Colors.white : JellyTheme.textPrimaryLight,
              ),
            ),
          ),
          Expanded(
            child: SliderTheme(
              data: const SliderThemeData(
                trackHeight: 2,
                thumbShape: RoundSliderThumbShape(enabledThumbRadius: 7),
              ),
              child: Slider(
                value: value.toDouble(),
                min: min.toDouble(),
                max: max.toDouble(),
                activeColor: JellyTheme.primary,
                onChanged: onChanged,
              ),
            ),
          ),
          Container(
            width: 52,
            alignment: Alignment.centerRight,
            child: Text(
              unit.isEmpty ? '$value' : '$value$unit',
              style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.bold,
                color: JellyTheme.primary,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildResolutionCard(bool isDark) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
      decoration: BoxDecoration(
        color: isDark ? JellyTheme.cardDark : JellyTheme.cardLight,
        borderRadius: BorderRadius.circular(14),
      ),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '设备分辨率',
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.bold,
                    color: isDark ? Colors.white : JellyTheme.textPrimaryLight,
                  ),
                ),
                const SizedBox(height: 1),
                Text(
                  '${_params.deviceWidth} × ${_params.deviceHeight}',
                  style: TextStyle(fontSize: 11, color: JellyTheme.textSecondary),
                ),
              ],
            ),
          ),
          TextButton.icon(
            onPressed: _editResolution,
            icon: const Icon(Icons.edit, size: 15),
            label: const Text('修改', style: TextStyle(fontSize: 13)),
          ),
        ],
      ),
    );
  }

  Widget _buildFooter(bool isDark) {
    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
        child: Row(
          children: [
            Expanded(
              flex: 1,
              child: OutlinedButton(
                onPressed: () => Navigator.of(context).pop(),
                style: OutlinedButton.styleFrom(
                  padding: const EdgeInsets.symmetric(vertical: 12),
                ),
                child: const Text('取消'),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              flex: 2,
              child: FilledButton(
                onPressed: _previewOriginals.isEmpty ? null : _confirmDownload,
                style: FilledButton.styleFrom(
                  padding: const EdgeInsets.symmetric(vertical: 12),
                ),
                child: Text(
                  '确认开始下载（${widget.selectedChapters.length} 话）',
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ============================================================
// Isolate 辅助
// ============================================================

class _PreviewIsolateRequest {
  final Uint8List bytes;
  final TrimParams params;
  const _PreviewIsolateRequest(this.bytes, this.params);
}

Uint8List? _processPreviewInIsolate(_PreviewIsolateRequest req) {
  return trimPreviewImage(req.bytes, req.params);
}
