import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_pdfview/flutter_pdfview.dart';

import '../services/book_download_service.dart';
import '../services/book_reading_progress_service.dart';
import '../theme/jelly_theme.dart';

void _log(String message) {
  if (kDebugMode) debugPrint('[PdfReader] $message');
}

/// PDF 阅读页：flutter_pdfview 用系统原生渲染（Android PdfRenderer / iOS PDFKit），
/// 无 PDFium、无构建时下载。自带滑动 + 捏合缩放 + 夜间模式。
///
/// 进度按页码存入 [BookReadingProgressService]：pageIndex = 当前页（0-based），
/// pageTotal = 总页数；与文字阅读器共用进度模型，"正在读 / 已读完"书架归位自动复用。
class PdfReaderPage extends StatefulWidget {
  final BookDownloadTask task;

  const PdfReaderPage({super.key, required this.task});

  @override
  State<PdfReaderPage> createState() => _PdfReaderPageState();
}

class _PdfReaderPageState extends State<PdfReaderPage> {
  PDFViewController? _controller;
  bool _loading = true;
  bool _fileMissing = false;
  bool _ready = false;
  String? _error;
  int _totalPages = 0;
  int _currentPage = 0; // 0-based，与 PDFView onPageChanged 一致
  int _defaultPage = 0;

  @override
  void initState() {
    super.initState();
    _init();
  }

  Future<void> _init() async {
    final path = widget.task.localPath;
    if (path == null || !await File(path).exists()) {
      if (mounted) {
        setState(() {
          _loading = false;
          _fileMissing = true;
        });
      }
      return;
    }
    // 恢复进度：pageIndex 为 0-based 页码，直接作 defaultPage
    final rp = BookReadingProgressService().getProgress(widget.task.bookId);
    if (rp != null && rp.pageIndex >= 0) {
      _defaultPage = rp.pageIndex;
      _currentPage = rp.pageIndex;
    }
    if (mounted) setState(() => _loading = false);
  }

  void _onPageChanged(int? page, int? total) {
    if (page == null) return;
    if (total != null && total > 0 && total != _totalPages) {
      _totalPages = total;
    }
    if (page == _currentPage) return;
    setState(() => _currentPage = page);
    _saveProgress(page);
  }

  void _saveProgress(int page0Based, {bool notify = true}) {
    final total = _totalPages;
    if (total <= 0 || page0Based < 0) return;
    BookReadingProgressService().recordBlock(
      widget.task.bookId,
      page0Based,
      page0Based,
      total,
      notify: notify,
    );
  }

  Future<void> _seekTo(int page1Based) async {
    final controller = _controller;
    if (controller == null) return;
    final page0 = page1Based - 1;
    if (page0 < 0 || page0 >= _totalPages) return;
    try {
      final ok = await controller.setPage(page0);
      // setPage 后若页码相同，onPageChanged 会被去重而不落盘，这里兜底
      if (ok == true) _saveProgress(page0);
    } catch (e) {
      _log('跳页失败: $e');
    }
  }

  @override
  void dispose() {
    if (_totalPages > 0 && _currentPage >= 0) {
      _saveProgress(_currentPage, notify: false);
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final bgColor = isDark
        ? JellyTheme.backgroundDark
        : JellyTheme.backgroundLight;
    return Scaffold(
      backgroundColor: bgColor,
      appBar: AppBar(
        backgroundColor: isDark ? JellyTheme.cardDark : JellyTheme.cardLight,
        foregroundColor: isDark ? Colors.white : JellyTheme.textPrimaryLight,
        title: Text(
          widget.task.title,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        actions: [_pageIndicator()],
        bottom: _totalPages > 1 ? _buildSeekBar() : null,
      ),
      body: _buildBody(isDark, bgColor),
    );
  }

  Widget _pageIndicator() {
    final cur = _currentPage + 1;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12),
      child: Center(
        child: Text(
          _totalPages > 0 ? '$cur / $_totalPages' : '$cur',
          style: const TextStyle(fontSize: 14),
        ),
      ),
    );
  }

  PreferredSizeWidget _buildSeekBar() {
    final max = _totalPages.toDouble();
    return PreferredSize(
      preferredSize: const Size.fromHeight(40),
      child: SliderTheme(
        data: SliderTheme.of(context).copyWith(
          trackHeight: 2,
          thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 6),
          overlayShape: const RoundSliderOverlayShape(overlayRadius: 12),
        ),
        child: Slider(
          min: 1,
          max: max,
          value: (_currentPage + 1).toDouble().clamp(1, max),
          onChanged: (v) => setState(() => _currentPage = v.round() - 1),
          onChangeEnd: (v) => _seekTo(v.round()),
        ),
      ),
    );
  }

  Widget _buildBody(bool isDark, Color bgColor) {
    if (_loading) return const Center(child: CircularProgressIndicator());
    if (_fileMissing) return _message('文件不存在，请重新下载');
    final path = widget.task.localPath!;
    return Stack(
      children: [
        PDFView(
          filePath: path,
          defaultPage: _defaultPage,
          enableSwipe: true,
          swipeHorizontal: true,
          nightMode: isDark,
          autoSpacing: true,
          pageFling: true,
          pageSnap: true,
          fitPolicy: FitPolicy.WIDTH,
          backgroundColor: bgColor,
          onViewCreated: (controller) => _controller = controller,
          onRender: (pages) {
            if (mounted) {
              setState(() {
                _ready = true;
                _totalPages = pages ?? _totalPages;
              });
            }
          },
          onPageChanged: _onPageChanged,
          onError: (error) {
            _log('PDF 渲染错误: $error');
            if (mounted) {
              setState(() => _error = '无法打开 PDF（可能已损坏或加密）：\n$error');
            }
          },
          onPageError: (page, error) {
            _log('PDF 第${page ?? '?'}页渲染错误: $error');
          },
        ),
        if (!_ready && _error == null)
          const Center(child: CircularProgressIndicator()),
        if (_error != null) _message(_error!),
      ],
    );
  }

  Widget _message(String text) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Text(
          text,
          textAlign: TextAlign.center,
          style: TextStyle(
            color: Theme.of(context).brightness == Brightness.dark
                ? Colors.white70
                : Colors.black54,
          ),
        ),
      ),
    );
  }
}
