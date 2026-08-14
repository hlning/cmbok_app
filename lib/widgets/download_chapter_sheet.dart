import 'package:flutter/material.dart';

import '../models/comic.dart';
import '../models/trim_preset.dart';
import '../pages/trim_preview_page.dart';
import '../services/download_service.dart';
import '../services/settings_service.dart';
import '../theme/jelly_theme.dart';

/// 章节选择底部弹窗（网格多列自适应）
/// 勾选章节 -> 加入下载队列 -> 提示并关闭（进度去"下载中"页查看）
class DownloadChapterSheet extends StatefulWidget {
  final Comic comic;
  final List<ComicChapter> chapters; // 当前分组章节
  final String groupName;

  const DownloadChapterSheet({
    super.key,
    required this.comic,
    required this.chapters,
    required this.groupName,
  });

  @override
  State<DownloadChapterSheet> createState() => _DownloadChapterSheetState();
}

class _DownloadChapterSheetState extends State<DownloadChapterSheet> {
  final Set<String> _selected = {};

  /// 可下载章节（未下载的）
  List<ComicChapter> get _downloadable => widget.chapters
      .where(
        (c) =>
            !DownloadService().isChapterDownloaded(widget.comic.pathWord, c.id),
      )
      .toList();

  void _toggle(String id) {
    setState(() {
      if (_selected.contains(id)) {
        _selected.remove(id);
      } else {
        _selected.add(id);
      }
    });
  }

  void _toggleAll() {
    final downloadable = _downloadable;
    setState(() {
      if (_selected.length == downloadable.length && downloadable.isNotEmpty) {
        _selected.clear();
      } else {
        _selected
          ..clear()
          ..addAll(downloadable.map((c) => c.id));
      }
    });
  }

  void _startDownload() {
    final toDownload = widget.chapters
        .where((c) => _selected.contains(c.id))
        .toList();
    if (toDownload.isEmpty) return;

    // 未开启去白边 → 直接下载
    if (!SettingsService().trimWhitespace) {
      _doDownload(toDownload, null);
      return;
    }

    // 开启了去白边 → 弹确认对话框
    _showTrimConfirmDialog(toDownload);
  }

  void _doDownload(List<ComicChapter> chapters, TrimParams? trimParams) {
    DownloadService().downloadChapters(widget.comic, chapters,
        trimParams: trimParams);
    if (!mounted) return;
    final messenger = ScaffoldMessenger.of(context);
    Navigator.of(context).pop();
    messenger
      ..hideCurrentSnackBar()
      ..showSnackBar(
        const SnackBar(
          content: Text('加入下载队列成功，请到下载中查看进度'),
          duration: Duration(seconds: 2),
          behavior: SnackBarBehavior.floating,
        ),
      );
  }

  /// 去白边确认对话框
  Future<void> _showTrimConfirmDialog(List<ComicChapter> toDownload) async {
    final result = await showDialog<bool>(
      context: context,
      builder: (ctx) {
        final isDark = Theme.of(ctx).brightness == Brightness.dark;
        return AlertDialog(
          backgroundColor: isDark ? JellyTheme.cardDark : Colors.white,
          shape:
              RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
          title: const Text('去白边下载'),
          content: const Text('系统检测到开启了下载去白边功能，是否对本次下载应用去白边？'),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(false),
              child: const Text('不去白边'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(ctx).pop(true),
              child: const Text('去白边'),
            ),
          ],
        );
      },
    );

    if (!mounted) return;
    if (result == null) return; // 取消

    if (result == false) {
      // 不去白边 → 直接下载
      _doDownload(toDownload, null);
    } else {
      // 去白边 → 跳转到预览页（先关闭底部面板）
      Navigator.of(context).pop(); // 关闭 BottomSheet
      Navigator.of(context).push(
        MaterialPageRoute(
          builder: (_) => TrimPreviewPage(
            comic: widget.comic,
            selectedChapters: toDownload,
          ),
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final svc = DownloadService();
    return DraggableScrollableSheet(
      initialChildSize: 0.6,
      minChildSize: 0.3,
      maxChildSize: 0.9,
      expand: false,
      builder: (context, scrollController) {
        return Container(
          decoration: BoxDecoration(
            color: isDark ? JellyTheme.cardDark : Colors.white,
            borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
          ),
          child: Column(
            children: [
              _buildHandle(),
              _buildTitle(isDark, svc),
              Expanded(child: _buildGrid(svc, scrollController, isDark)),
              _buildFooter(),
            ],
          ),
        );
      },
    );
  }

  Widget _buildHandle() {
    return Padding(
      padding: const EdgeInsets.only(top: 8, bottom: 4),
      child: Container(
        width: 40,
        height: 4,
        decoration: BoxDecoration(
          color: Colors.grey[400],
          borderRadius: BorderRadius.circular(2),
        ),
      ),
    );
  }

  Widget _buildTitle(bool isDark, DownloadService svc) {
    final downloadedCount = widget.chapters
        .where((c) => svc.isChapterDownloaded(widget.comic.pathWord, c.id))
        .length;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
      child: Row(
        children: [
          Text(
            '${widget.groupName} · 共 ${widget.chapters.length} 话',
            style: TextStyle(
              fontSize: 15,
              fontWeight: FontWeight.bold,
              color: isDark ? Colors.white : JellyTheme.textPrimaryLight,
            ),
          ),
          const Spacer(),
          if (downloadedCount > 0)
            Text(
              '已下载 $downloadedCount',
              style: TextStyle(fontSize: 12, color: JellyTheme.success),
            ),
        ],
      ),
    );
  }

  /// 章节网格：列数随宽度自适应（maxCrossAxisExtent 限制单格最大宽）
  Widget _buildGrid(
    DownloadService svc,
    ScrollController controller,
    bool isDark,
  ) {
    if (widget.chapters.isEmpty) {
      return Center(
        child: Text(
          '暂无章节',
          style: TextStyle(
            color: isDark ? Colors.white54 : JellyTheme.textSecondary,
          ),
        ),
      );
    }
    return GridView.builder(
      controller: controller,
      padding: const EdgeInsets.fromLTRB(10, 4, 10, 8),
      gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
        maxCrossAxisExtent: 140,
        childAspectRatio: 3.2,
        crossAxisSpacing: 6,
        mainAxisSpacing: 6,
      ),
      itemCount: widget.chapters.length,
      itemBuilder: (context, index) {
        final chapter = widget.chapters[index];
        final downloaded = svc.isChapterDownloaded(
          widget.comic.pathWord,
          chapter.id,
        );
        final selected = _selected.contains(chapter.id);
        return _buildChapterCell(chapter, downloaded, selected, isDark);
      },
    );
  }

  Widget _buildChapterCell(
    ComicChapter chapter,
    bool downloaded,
    bool selected,
    bool isDark,
  ) {
    final disabledColor = isDark ? Colors.white38 : Colors.black38;
    return GestureDetector(
      onTap: downloaded ? null : () => _toggle(chapter.id),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
        decoration: BoxDecoration(
          color: selected
              ? JellyTheme.primary.withValues(alpha: 0.15)
              : (isDark
                    ? Colors.white.withValues(alpha: 0.05)
                    : Colors.black.withValues(alpha: 0.03)),
          borderRadius: BorderRadius.circular(8),
          border: Border.all(
            color: selected
                ? JellyTheme.primary
                : (downloaded
                      ? Colors.transparent
                      : (isDark ? Colors.white24 : Colors.black12)),
          ),
        ),
        child: Row(
          children: [
            Icon(
              downloaded
                  ? Icons.check_circle
                  : (selected
                        ? Icons.check_circle
                        : Icons.radio_button_unchecked),
              size: 16,
              color: downloaded
                  ? JellyTheme.success
                  : (selected
                        ? JellyTheme.primary
                        : (isDark ? Colors.white38 : Colors.black38)),
            ),
            const SizedBox(width: 4),
            Expanded(
              child: Text(
                chapter.title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 11,
                  color: downloaded ? disabledColor : null,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildFooter() {
    final downloadable = _downloadable;
    final allSelected =
        _selected.length == downloadable.length && downloadable.isNotEmpty;
    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
        child: Row(
          children: [
            TextButton.icon(
              onPressed: _toggleAll,
              icon: Icon(
                allSelected ? Icons.deselect : Icons.select_all,
                size: 18,
              ),
              label: Text(allSelected ? '取消全选' : '全选'),
            ),
            const Spacer(),
            FilledButton(
              onPressed: _selected.isEmpty ? null : _startDownload,
              child: Text(
                _selected.isEmpty ? '下载' : '下载 ${_selected.length} 话',
              ),
            ),
          ],
        ),
      ),
    );
  }
}
