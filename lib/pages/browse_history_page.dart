import 'dart:math' show min;

import 'package:flutter/material.dart';
import '../models/book.dart';
import '../models/comic.dart';
import '../services/browse_history_service.dart';
import '../theme/jelly_theme.dart';
import '../utils/list_pagination.dart';
import '../widgets/jelly_book_card.dart';
import '../widgets/jelly_comic_list_tile.dart';
import '../widgets/jelly_segmented_toggle.dart';
import 'book_detail_page.dart';
import 'comic_detail_page.dart';

/// 浏览记录页。
/// - 从「我的」进入：showTabs=true，顶部漫画/图书切换 + 右侧清理按钮。
/// - 从漫画搜索进入：showTabs=false，仅漫画，清理按钮在 AppBar 右上角。
/// 只展示从搜索页进入详情的记录，点击记录跳详情（不含多选/删除等其他功能）。
class BrowseHistoryPage extends StatefulWidget {
  final bool showTabs;

  const BrowseHistoryPage({super.key, this.showTabs = true});

  @override
  State<BrowseHistoryPage> createState() => _BrowseHistoryPageState();
}

class _BrowseHistoryPageState extends State<BrowseHistoryPage>
    with TickerProviderStateMixin {
  TabController? _tabController;

  @override
  void initState() {
    super.initState();
    if (widget.showTabs) {
      _tabController = TabController(length: 2, vsync: this);
      _tabController!.addListener(_onTabChanged);
    }
  }

  @override
  void dispose() {
    _tabController?.removeListener(_onTabChanged);
    _tabController?.dispose();
    super.dispose();
  }

  void _onTabChanged() {
    if (!mounted) return;
    if (!_tabController!.indexIsChanging) setState(() {});
  }

  // showTabs=false 时恒为漫画
  bool get _isComicTab => !widget.showTabs || _tabController!.index == 0;

  @override
  Widget build(BuildContext context) {
    // tab 总宽 = 屏幕一半（与收藏页一致）
    final tabSegWidth = (MediaQuery.of(context).size.width * 0.5 - 10) / 2;
    return Scaffold(
      appBar: AppBar(
        title: const Text('浏览记录'),
        actions: [
          // 仅漫画模式：清理按钮放 AppBar 右上角（参考下载记录）
          if (!widget.showTabs)
            IconButton(
              icon: const Icon(Icons.delete_sweep_rounded),
              tooltip: '清理',
              onPressed: () => _showCleanSheet(isComic: true),
            ),
        ],
      ),
      body: widget.showTabs
          ? Column(
              children: [
                // 漫画/图书 切换 + 右侧清理按钮（参考收藏页搜索按钮）
                Padding(
                  padding: const EdgeInsets.fromLTRB(12, 6, 12, 6),
                  child: Row(
                    children: [
                      const Spacer(),
                      AnimatedBuilder(
                        animation: _tabController!.animation!,
                        builder: (context, _) => JellySegmentedToggle(
                          index: _tabController!.animation!.value,
                          onChanged: (i) => _tabController!.animateTo(i),
                          segmentWidth: tabSegWidth,
                          segments: const [
                            JellySegmentData(icon: Icons.palette_rounded),
                            JellySegmentData(icon: Icons.book_rounded),
                          ],
                        ),
                      ),
                      const SizedBox(width: 8),
                      _buildCleanButton(),
                      const Spacer(),
                    ],
                  ),
                ),
                Expanded(
                  child: TabBarView(
                    controller: _tabController,
                    children: const [_ComicHistoryTab(), _BookHistoryTab()],
                  ),
                ),
              ],
            )
          : const _ComicHistoryTab(),
    );
  }

  /// 圆形清理按钮（样式同收藏页搜索按钮）
  Widget _buildCleanButton() {
    return Material(
      color: JellyTheme.primary,
      shape: const CircleBorder(),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: () => _showCleanSheet(isComic: _isComicTab),
        child: const SizedBox(
          width: 36,
          height: 36,
          child: Icon(
            Icons.delete_sweep_rounded,
            color: Colors.white,
            size: 20,
          ),
        ),
      ),
    );
  }

  /// 清理选项：所有 / 一周前 / 一月前
  void _showCleanSheet({required bool isComic}) {
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (ctx) {
        Widget option(String label, int? beforeTs) => ListTile(
              title: Text(label),
              trailing: const Icon(Icons.chevron_right_rounded),
              onTap: () {
                Navigator.pop(ctx);
                _confirmClean(
                  isComic: isComic,
                  beforeTs: beforeTs,
                  label: label,
                );
              },
            );
        final now = DateTime.now().millisecondsSinceEpoch;
        return SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              option('所有', null),
              option('一周前', now - const Duration(days: 7).inMilliseconds),
              option('一月前', now - const Duration(days: 30).inMilliseconds),
            ],
          ),
        );
      },
    );
  }

  Future<void> _confirmClean({
    required bool isComic,
    required int? beforeTs,
    required String label,
  }) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('清理浏览记录'),
        content: Text(
          '确定清理「$label」的${isComic ? '漫画' : '图书'}浏览记录吗？',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('确定'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    if (isComic) {
      await BrowseHistoryService().clearComics(beforeTs: beforeTs);
    } else {
      await BrowseHistoryService().clearBooks(beforeTs: beforeTs);
    }
  }
}

/// 漫画浏览记录列表（懒加载分页，默认 20 条，滑到底加载更多）
class _ComicHistoryTab extends StatefulWidget {
  const _ComicHistoryTab();

  @override
  State<_ComicHistoryTab> createState() => _ComicHistoryTabState();
}

class _ComicHistoryTabState extends State<_ComicHistoryTab> {
  static const _pageSize = 20;

  final ScrollController _scrollController = ScrollController();
  int _displayCount = _pageSize;

  @override
  void initState() {
    super.initState();
    _scrollController.addListener(_onScroll);
  }

  @override
  void dispose() {
    _scrollController.removeListener(_onScroll);
    _scrollController.dispose();
    super.dispose();
  }

  void _onScroll() {
    if (!_scrollController.hasClients) return;
    final total = BrowseHistoryService().comics.length;
    if (ListPagination.shouldLoadMore(_scrollController) &&
        _displayCount < total) {
      setState(() => _displayCount += _pageSize);
    }
  }

  void _openDetail(Comic comic) {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => ComicDetailPage(
          comic: comic,
          heroTag: comicCoverHeroTag('history', comic),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: BrowseHistoryService(),
      builder: (context, _) {
        final comics = BrowseHistoryService().comics;
        if (comics.isEmpty) return _buildEmpty();
        return Column(
          children: [
            ListPaginationCountBar(total: comics.length, unit: '条'),
            Expanded(
              child: ListView.builder(
                controller: _scrollController,
                padding: const EdgeInsets.fromLTRB(12, 0, 12, 16),
                itemCount: min(comics.length, _displayCount),
                itemBuilder: (context, index) {
                  final comic = comics[index];
                  return Padding(
                    padding: const EdgeInsets.only(bottom: 12),
                    child: JellyComicListTile(
                      comic: comic,
                      heroTag: comicCoverHeroTag('history', comic),
                      showSourceBadge: true,
                      onTap: () => _openDetail(comic),
                    ),
                  );
                },
              ),
            ),
          ],
        );
      },
    );
  }
}

/// 图书浏览记录列表
class _BookHistoryTab extends StatefulWidget {
  const _BookHistoryTab();

  @override
  State<_BookHistoryTab> createState() => _BookHistoryTabState();
}

class _BookHistoryTabState extends State<_BookHistoryTab> {
  static const _pageSize = 20;

  final ScrollController _scrollController = ScrollController();
  int _displayCount = _pageSize;

  @override
  void initState() {
    super.initState();
    _scrollController.addListener(_onScroll);
  }

  @override
  void dispose() {
    _scrollController.removeListener(_onScroll);
    _scrollController.dispose();
    super.dispose();
  }

  void _onScroll() {
    if (!_scrollController.hasClients) return;
    final total = BrowseHistoryService().books.length;
    if (ListPagination.shouldLoadMore(_scrollController) &&
        _displayCount < total) {
      setState(() => _displayCount += _pageSize);
    }
  }

  void _openDetail(Book book) {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => BookDetailPage(
          book: book,
          heroTag: bookCoverHeroTag('history', book),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: BrowseHistoryService(),
      builder: (context, _) {
        final books = BrowseHistoryService().books;
        if (books.isEmpty) return _buildEmpty();
        return Column(
          children: [
            ListPaginationCountBar(total: books.length, unit: '条'),
            Expanded(
              child: ListView.builder(
                controller: _scrollController,
                padding: const EdgeInsets.fromLTRB(12, 0, 12, 16),
                itemCount: min(books.length, _displayCount),
                itemBuilder: (context, index) {
                  final book = books[index];
                  return Padding(
                    padding: const EdgeInsets.only(bottom: 12),
                    child: JellyBookCard(
                      book: book,
                      isGrid: false,
                      heroTag: bookCoverHeroTag('history', book),
                      onTap: () => _openDetail(book),
                    ),
                  );
                },
              ),
            ),
          ],
        );
      },
    );
  }
}

Widget _buildEmpty() {
  return Center(
    child: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(Icons.history_rounded, size: 56, color: Colors.grey[400]),
        const SizedBox(height: 12),
        Text('暂无浏览记录', style: TextStyle(color: Colors.grey[500])),
      ],
    ),
  );
}
