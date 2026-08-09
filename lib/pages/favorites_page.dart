import 'dart:math' show min;
import 'dart:ui';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_staggered_grid_view/flutter_staggered_grid_view.dart';
import '../models/book.dart';
import '../models/comic.dart';
import '../services/book_favorites_service.dart';
import '../services/book_view_mode.dart';
import '../services/favorites_service.dart';
import '../services/view_mode.dart';
import '../theme/jelly_theme.dart';
import '../widgets/jelly_book_card.dart';
import '../widgets/jelly_select_badge.dart';
import '../services/settings_service.dart';
import '../utils/list_pagination.dart';
import '../widgets/jelly_comic_card.dart';
import '../widgets/jelly_comic_list_tile.dart';
import '../widgets/jelly_nav_bar.dart';
import '../widgets/jelly_search_bar.dart';
import '../widgets/jelly_segmented_toggle.dart';
import '../widgets/staggered_entrance.dart';
import 'book_detail_page.dart';
import 'comic_detail_page.dart';

/// 收藏页面（顶部 Tab：漫画收藏 / 图书收藏）
class FavoritesPage extends StatefulWidget {
  /// 是否为当前激活的 tab（用于触发收藏卡片入场动画）
  final bool isActive;

  /// 是否显示返回按钮（从"我的"页面入口进入时为 true）
  final bool showBackButton;

  const FavoritesPage({
    super.key,
    this.isActive = false,
    this.showBackButton = false,
  });

  @override
  State<FavoritesPage> createState() => _FavoritesPageState();
}

class _FavoritesPageState extends State<FavoritesPage>
    with TickerProviderStateMixin {
  late TabController _tabController;

  // 多选模式
  bool _isSelecting = false;
  final Set<String> _selectedIds = {};

  // 搜索浮层
  bool _searchVisible = false;
  late final AnimationController _searchAnim;
  final TextEditingController _favSearchController = TextEditingController();
  String _favQuery = '';

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 2, vsync: this);
    _tabController.addListener(_onTabChanged);
    _searchAnim = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 300),
    );
  }

  void _onTabChanged() {
    // 切换 tab 时退出多选，避免不同类型 id 混乱
    if (_isSelecting && _tabController.indexIsChanging) {
      setState(() {
        _isSelecting = false;
        _selectedIds.clear();
      });
    }
  }

  @override
  void dispose() {
    _tabController.removeListener(_onTabChanged);
    _tabController.dispose();
    _searchAnim.dispose();
    _favSearchController.dispose();
    super.dispose();
  }

  void _openSearch() {
    setState(() => _searchVisible = true);
    _searchAnim.forward();
  }

  void _closeSearch() {
    _searchAnim.reverse().then((_) {
      if (mounted) {
        _favSearchController.clear();
        setState(() {
          _searchVisible = false;
          _favQuery = '';
        });
      }
    });
  }

  void _openDetail(Comic comic) {
    Navigator.push(
      context,
      MaterialPageRoute(builder: (context) => ComicDetailPage(comic: comic)),
    );
  }

  String _formatPopular(int popular) {
    if (popular >= 10000) return '${(popular / 10000).toStringAsFixed(1)}万';
    return popular.toString();
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    // tab 总宽 = 屏幕一半：段宽*2 + 左右各5内边距 = 屏幕宽/2
    final tabSegWidth = (MediaQuery.of(context).size.width * 0.5 - 10) / 2;
    return PopScope(
      canPop: !_isSelecting,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop && _isSelecting) _exitSelection();
      },
      child: Scaffold(
        appBar: widget.showBackButton ? AppBar(title: const Text('收藏')) : null,
        body: Stack(
          children: [
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SafeArea(
                  top: !widget.showBackButton,
                  bottom: false,
                  child: SizedBox(
                    height: widget.showBackButton ? 70 : 105,
                    child: Stack(
                      children: [
                        // 标题：左上角，间距小（AppBar 模式下由 AppBar 承担）
                        if (!widget.showBackButton)
                          Positioned(
                            top: 6,
                            left: 16,
                            child: Text(
                              '收藏',
                              style: TextStyle(
                                fontSize: 22,
                                fontWeight: FontWeight.bold,
                                color: isDark
                                    ? Colors.white
                                    : JellyTheme.textPrimaryLight,
                              ),
                            ),
                          ),
                        // 控件组：水平居中，间距大（往下错开，层次感）
                        Positioned(
                          top: widget.showBackButton ? 6 : 45,
                          left: 12,
                          right: 12,
                          child: Row(
                            children: [
                              const Spacer(),
                              AnimatedBuilder(
                                animation: _tabController.animation!,
                                builder: (context, _) => JellySegmentedToggle(
                                  index: _tabController.animation!.value,
                                  onChanged: (i) => _tabController.animateTo(i),
                                  segmentWidth: tabSegWidth,
                                  segments: const [
                                    JellySegmentData(
                                      icon: Icons.palette_rounded,
                                    ),
                                    JellySegmentData(icon: Icons.book_rounded),
                                  ],
                                ),
                              ),
                              const SizedBox(width: 8),
                              Material(
                                color: JellyTheme.primary,
                                shape: const CircleBorder(),
                                clipBehavior: Clip.antiAlias,
                                child: InkWell(
                                  onTap: _openSearch,
                                  child: const SizedBox(
                                    width: 50,
                                    height: 50,
                                    child: Icon(
                                      Icons.search_rounded,
                                      color: Colors.white,
                                      size: 22,
                                    ),
                                  ),
                                ),
                              ),
                              const Spacer(),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
                Expanded(
                  child: TabBarView(
                    controller: _tabController,
                    children: [
                      _ComicFavoritesTab(
                        isActive: widget.isActive,
                        isSelecting: _isSelecting,
                        selectedIds: _selectedIds,
                        onSelect: _onSelect,
                      ),
                      _BookFavoritesTab(
                        isSelecting: _isSelecting,
                        selectedIds: _selectedIds,
                        onSelect: _onSelect,
                      ),
                    ],
                  ),
                ),
              ],
            ),
            if (_searchVisible) _buildSearchOverlay(),
            if (_isSelecting)
              Positioned(
                left: 20,
                right: 20,
                bottom: SettingsService().navFloating
                    ? JellyNavBar.floatingTotalHeight + 8
                    : 16.0,
                child: Center(child: _buildSelectionBar(isDark)),
              ),
          ],
        ),
      ),
    );
  }

  // ===== 多选模式 =====

  void _onSelect(String id) {
    setState(() {
      if (!_isSelecting) {
        _isSelecting = true;
        _selectedIds
          ..clear()
          ..add(id);
      } else if (_selectedIds.contains(id)) {
        _selectedIds.remove(id);
      } else {
        _selectedIds.add(id);
      }
    });
  }

  void _exitSelection() {
    setState(() {
      _isSelecting = false;
      _selectedIds.clear();
    });
  }

  void _selectAll() {
    final isComic = _tabController.index == 0;
    setState(() {
      _selectedIds
        ..clear()
        ..addAll(
          isComic
              ? FavoritesService().comics.map((c) => c.id)
              : BookFavoritesService().books.map((b) => b.id),
        );
    });
  }

  Future<void> _removeSelected() async {
    if (_selectedIds.isEmpty) return;
    final isComic = _tabController.index == 0;
    final count = _selectedIds.length;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('取消收藏'),
        content: Text('确定取消收藏选中的 $count 项吗？'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('确定'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    if (isComic) {
      await FavoritesService().removeMany(_selectedIds);
    } else {
      await BookFavoritesService().removeMany(_selectedIds);
    }
    if (mounted) _exitSelection();
  }

  Widget _buildSelectionBar(bool isDark) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: isDark ? JellyTheme.cardDark : JellyTheme.cardLight,
        borderRadius: BorderRadius.circular(16),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: isDark ? 0.5 : 0.12),
            blurRadius: 12,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            '已选 ${_selectedIds.length} 项',
            style: TextStyle(
              fontSize: 14,
              fontWeight: FontWeight.w600,
              color: isDark ? Colors.white : JellyTheme.textPrimaryLight,
            ),
          ),
          const SizedBox(width: 12),
          TextButton(onPressed: _selectAll, child: const Text('全选')),
          const SizedBox(width: 4),
          FilledButton(
            onPressed: _selectedIds.isEmpty ? null : _removeSelected,
            child: const Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text('取消'),
                SizedBox(width: 4),
                Icon(Icons.favorite_border_rounded, size: 18),
              ],
            ),
          ),
          const SizedBox(width: 4),
          IconButton(
            onPressed: _exitSelection,
            icon: const Icon(Icons.close_rounded),
            tooltip: '退出多选',
          ),
        ],
      ),
    );
  }

  /// 搜索浮层：高斯模糊蒙版 + 居中搜索框/结果（带出场动画）
  Widget _buildSearchOverlay() {
    return Positioned.fill(
      child: Stack(
        children: [
          // 高斯模糊蒙版（点击关闭）
          Positioned.fill(
            child: GestureDetector(
              onTap: _closeSearch,
              behavior: HitTestBehavior.opaque,
              child: FadeTransition(
                opacity: _searchAnim,
                child: BackdropFilter(
                  filter: ImageFilter.blur(sigmaX: 12, sigmaY: 12),
                  child: Container(color: Colors.black.withValues(alpha: 0.2)),
                ),
              ),
            ),
          ),
          // 居中搜索框 + 结果（缩放淡入）
          Center(
            child: FadeTransition(
              opacity: _searchAnim,
              child: ScaleTransition(
                scale: Tween<double>(begin: 0.92, end: 1.0).animate(
                  CurvedAnimation(
                    parent: _searchAnim,
                    curve: Curves.easeOutBack,
                  ),
                ),
                child: _buildSearchContent(),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSearchContent() {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final q = _favQuery.trim().toLowerCase();
    final comics = FavoritesService().comics
        .where(
          (c) =>
              q.isEmpty ||
              c.title.toLowerCase().contains(q) ||
              (c.alias?.toLowerCase().contains(q) ?? false) ||
              (c.author?.toLowerCase().contains(q) ?? false),
        )
        .toList();
    final books = BookFavoritesService().books
        .where(
          (b) =>
              q.isEmpty ||
              b.title.toLowerCase().contains(q) ||
              (b.author?.toLowerCase().contains(q) ?? false),
        )
        .toList();
    // 交错合并漫画/图书，使两者都有机会展示；再限制前 10 条
    final all = <dynamic>[];
    var ci = 0, bi = 0;
    while (ci < comics.length || bi < books.length) {
      if (ci < comics.length) {
        all.add(comics[ci]);
        ci++;
      }
      if (bi < books.length) {
        all.add(books[bi]);
        bi++;
      }
    }
    const maxResults = 10;
    final limited = all.take(maxResults).toList();
    final hasMore = all.length > maxResults;
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          JellySearchBar(
            controller: _favSearchController,
            hintText: '搜索收藏',
            autofocus: true,
            onChanged: (v) => setState(() => _favQuery = v),
            onCleared: () => setState(() => _favQuery = ''),
          ),
          const SizedBox(height: 12),
          SizedBox(
            height: MediaQuery.of(context).size.height * 0.4,
            child: Material(
              color: isDark ? const Color(0xFF252542) : Colors.white,
              borderRadius: BorderRadius.circular(20),
              clipBehavior: Clip.antiAlias,
              child: all.isEmpty
                  ? const Center(
                      child: Padding(
                        padding: EdgeInsets.all(24),
                        child: Text(
                          '无匹配结果',
                          style: TextStyle(color: Colors.grey),
                        ),
                      ),
                    )
                  : ListView.builder(
                      padding: const EdgeInsets.symmetric(vertical: 4),
                      itemCount: limited.length + (hasMore ? 1 : 0),
                      itemBuilder: (context, index) {
                        if (index == limited.length) {
                          return Padding(
                            padding: const EdgeInsets.all(12),
                            child: Center(
                              child: Text(
                                '仅显示前 $maxResults 条，共 ${all.length} 条',
                                style: const TextStyle(
                                  color: Colors.grey,
                                  fontSize: 12,
                                ),
                              ),
                            ),
                          );
                        }
                        final item = limited[index];
                        if (item is Comic) return _buildComicResultTile(item);
                        return _buildBookResultTile(item as Book);
                      },
                    ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildComicResultTile(Comic comic) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return ListTile(
      leading: ClipRRect(
        borderRadius: BorderRadius.circular(6),
        child: CachedNetworkImage(
          imageUrl: comic.cover,
          width: 40,
          height: 56,
          fit: BoxFit.cover,
          placeholder: (c, u) =>
              Container(color: Colors.grey[300], width: 40, height: 56),
          errorWidget: (c, u, e) => Container(
            color: Colors.grey[300],
            width: 40,
            height: 56,
            child: const Icon(Icons.broken_image, size: 20, color: Colors.grey),
          ),
        ),
      ),
      title: Text(comic.title, maxLines: 1, overflow: TextOverflow.ellipsis),
      subtitle: Text(
        [
          comic.author,
          comic.alias,
          if (comic.popular != null && comic.popular! > 0)
            '🔥${_formatPopular(comic.popular!)}',
        ].whereType<String>().where((s) => s.isNotEmpty).join(' · '),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: const TextStyle(fontSize: 12),
      ),
      trailing: Icon(
        Icons.palette_rounded,
        size: 18,
        color: isDark ? Colors.white24 : Colors.black26,
      ),
      onTap: () {
        _closeSearch();
        _openDetail(comic);
      },
    );
  }

  Widget _buildBookResultTile(Book book) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return ListTile(
      leading: ClipRRect(
        borderRadius: BorderRadius.circular(6),
        child: (book.cover ?? '').isEmpty
            ? Container(
                color: Colors.grey[300],
                width: 40,
                height: 56,
                child: const Icon(
                  Icons.menu_book_rounded,
                  size: 20,
                  color: Colors.grey,
                ),
              )
            : CachedNetworkImage(
                imageUrl: book.cover!,
                width: 40,
                height: 56,
                fit: BoxFit.cover,
                placeholder: (c, u) =>
                    Container(color: Colors.grey[300], width: 40, height: 56),
                errorWidget: (c, u, e) => Container(
                  color: Colors.grey[300],
                  width: 40,
                  height: 56,
                  child: const Icon(
                    Icons.broken_image,
                    size: 20,
                    color: Colors.grey,
                  ),
                ),
              ),
      ),
      title: Text(book.title, maxLines: 1, overflow: TextOverflow.ellipsis),
      subtitle: Text(
        [
          book.author,
          book.extension?.toUpperCase(),
        ].whereType<String>().where((s) => s.isNotEmpty).join(' · '),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: const TextStyle(fontSize: 12),
      ),
      trailing: Icon(
        Icons.book_rounded,
        size: 18,
        color: isDark ? Colors.white24 : Colors.black26,
      ),
      onTap: () {
        _closeSearch();
        _openBookDetail(book);
      },
    );
  }

  /// 打开图书详情（不传搜索结果 -> 详情页以作者搜索推荐）
  void _openBookDetail(Book book) {
    Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => BookDetailPage(book: book)),
    );
  }
}

/// 漫画收藏（跟随搜索页视图模式，列数自适应 + 置顶按钮）
class _ComicFavoritesTab extends StatefulWidget {
  final bool isActive;
  final bool isSelecting;
  final Set<String> selectedIds;
  final ValueChanged<String> onSelect;

  const _ComicFavoritesTab({
    this.isActive = false,
    this.isSelecting = false,
    this.selectedIds = const {},
    required this.onSelect,
  });

  @override
  State<_ComicFavoritesTab> createState() => _ComicFavoritesTabState();
}

class _ComicFavoritesTabState extends State<_ComicFavoritesTab> {
  final ScrollController _scrollController = ScrollController();
  bool _showBackToTop = false;
  int _session = 0; // 首次切到收藏 tab 时 +1，触发卡片瀑布入场动画
  bool _hasShownEntrance = false; // 是否已播过首次入场动画
  int _displayCount = ListPagination.pageSize; // 滚动懒加载：当前渲染条数

  @override
  void initState() {
    super.initState();
    _scrollController.addListener(_onScroll);
  }

  @override
  void didUpdateWidget(covariant _ComicFavoritesTab oldWidget) {
    super.didUpdateWidget(oldWidget);
    // 仅首次切到收藏 tab 时重播入场动画，之后切回不再触发（避免闪烁）
    if (widget.isActive && !oldWidget.isActive && !_hasShownEntrance) {
      _hasShownEntrance = true;
      setState(() => _session++);
    }
  }

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  void _onScroll() {
    if (!_scrollController.hasClients) return;
    final total = FavoritesService().comics.length;
    if (ListPagination.shouldLoadMore(_scrollController) &&
        _displayCount < total) {
      setState(
        () =>
            _displayCount = min(_displayCount + ListPagination.pageSize, total),
      );
      return;
    }
    final show = _scrollController.position.pixels > 300;
    if (show != _showBackToTop) setState(() => _showBackToTop = show);
  }

  void _scrollToTop() {
    if (_scrollController.hasClients) {
      _scrollController.animateTo(
        0,
        duration: const Duration(milliseconds: 400),
        curve: Curves.easeOutCubic,
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: Listenable.merge([FavoritesService(), ViewMode()]),
      builder: (context, _) {
        final comics = FavoritesService().comics;
        final isGrid = ViewMode().isGrid;
        if (comics.isEmpty) {
          return const Center(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(
                  Icons.favorite_border_rounded,
                  size: 64,
                  color: Colors.grey,
                ),
                SizedBox(height: 16),
                Text('还没有收藏的漫画', style: TextStyle(color: Colors.grey)),
              ],
            ),
          );
        }
        return Column(
          children: [
            ListPaginationCountBar(total: comics.length, unit: '本'),
            Expanded(
              child: Stack(
                children: [
                  LayoutBuilder(
                    builder: (context, constraints) {
                      final cols = _adaptiveCols(
                        constraints.maxWidth,
                        min: isGrid ? 2 : 1,
                        target: isGrid ? 170 : 360,
                        max: isGrid ? 6 : 4,
                      );
                      return MasonryGridView.count(
                        controller: _scrollController,
                        padding: EdgeInsets.only(
                          top: 4,
                          left: 12,
                          right: 12,
                          bottom: 12 + JellyNavBar.contentBottomAvoid,
                        ),
                        crossAxisCount: cols,
                        mainAxisSpacing: 12,
                        crossAxisSpacing: 12,
                        itemCount: min(comics.length, _displayCount),
                        itemBuilder: (context, index) {
                          final comic = comics[index];
                          final selected = widget.selectedIds.contains(
                            comic.id,
                          );
                          final card = isGrid
                              ? JellyComicCard(
                                  comic: comic,
                                  heroTag: comicCoverHeroTag('fav', comic),
                                  onTap: widget.isSelecting
                                      ? () => widget.onSelect(comic.id)
                                      : () => _openDetail(context, comic),
                                  onLongPress: () => widget.onSelect(comic.id),
                                )
                              : JellyComicListTile(
                                  comic: comic,
                                  heroTag: comicCoverHeroTag('fav', comic),
                                  onTap: widget.isSelecting
                                      ? () => widget.onSelect(comic.id)
                                      : () => _openDetail(context, comic),
                                  onLongPress: () => widget.onSelect(comic.id),
                                );
                          return StaggeredEntrance(
                            key: ValueKey('${_session}_${comic.id}'),
                            index: index,
                            child: Stack(
                              children: [
                                card,
                                if (widget.isSelecting)
                                  Positioned(
                                    top: 4,
                                    right: 4,
                                    child: JellySelectBadge(selected: selected),
                                  ),
                              ],
                            ),
                          );
                        },
                      );
                    },
                  ),
                  // 置顶按钮
                  if (_showBackToTop && !widget.isSelecting)
                    ListenableBuilder(
                      listenable: SettingsService(),
                      builder: (context, _) {
                        final bottomOffset = SettingsService().navFloating
                            ? JellyNavBar.floatingTotalHeight + 8
                            : 16.0;
                        return Positioned(
                          bottom: bottomOffset,
                          right: 16,
                          child: AnimatedScale(
                            scale: _showBackToTop ? 1.0 : 0.0,
                            duration: const Duration(milliseconds: 200),
                            curve: Curves.easeOut,
                            child: Material(
                              color: JellyTheme.primary,
                              shape: const CircleBorder(),
                              elevation: 4,
                              clipBehavior: Clip.antiAlias,
                              child: InkWell(
                                onTap: _scrollToTop,
                                child: const SizedBox(
                                  width: 44,
                                  height: 44,
                                  child: Icon(
                                    Icons.arrow_upward_rounded,
                                    color: Colors.white,
                                    size: 22,
                                  ),
                                ),
                              ),
                            ),
                          ),
                        );
                      },
                    ),
                ],
              ),
            ),
          ],
        );
      },
    );
  }

  static int _adaptiveCols(
    double width, {
    required int min,
    int max = 6,
    double target = 170,
  }) {
    final available = width - 40;
    var cols = (available / target).floor();
    if (cols < min) cols = min;
    if (cols > max) cols = max;
    return cols;
  }

  static void _openDetail(BuildContext context, Comic comic) {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (context) => ComicDetailPage(
          comic: comic,
          heroTag: comicCoverHeroTag('fav', comic),
        ),
      ),
    );
  }
}

/// 图书收藏（跟随搜索页视图模式，列数自适应 + 置顶按钮）
class _BookFavoritesTab extends StatefulWidget {
  final bool isSelecting;
  final Set<String> selectedIds;
  final ValueChanged<String> onSelect;

  const _BookFavoritesTab({
    this.isSelecting = false,
    this.selectedIds = const {},
    required this.onSelect,
  });

  @override
  State<_BookFavoritesTab> createState() => _BookFavoritesTabState();
}

class _BookFavoritesTabState extends State<_BookFavoritesTab> {
  final ScrollController _scrollController = ScrollController();
  bool _showBackToTop = false;
  int _displayCount = ListPagination.pageSize; // 滚动懒加载：当前渲染条数

  @override
  void initState() {
    super.initState();
    _scrollController.addListener(_onScroll);
  }

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  void _onScroll() {
    if (!_scrollController.hasClients) return;
    final total = BookFavoritesService().books.length;
    if (ListPagination.shouldLoadMore(_scrollController) &&
        _displayCount < total) {
      setState(
        () =>
            _displayCount = min(_displayCount + ListPagination.pageSize, total),
      );
      return;
    }
    final show = _scrollController.position.pixels > 300;
    if (show != _showBackToTop) setState(() => _showBackToTop = show);
  }

  void _scrollToTop() {
    if (_scrollController.hasClients) {
      _scrollController.animateTo(
        0,
        duration: const Duration(milliseconds: 400),
        curve: Curves.easeOutCubic,
      );
    }
  }

  void _openDetail(Book book) {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) =>
            BookDetailPage(book: book, heroTag: bookCoverHeroTag('fav', book)),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: Listenable.merge([BookFavoritesService(), BookViewMode()]),
      builder: (context, _) {
        final books = BookFavoritesService().books;
        final isGrid = BookViewMode().isGrid;
        if (books.isEmpty) {
          return const Center(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(
                  Icons.favorite_border_rounded,
                  size: 64,
                  color: Colors.grey,
                ),
                SizedBox(height: 16),
                Text('还没有收藏的图书', style: TextStyle(color: Colors.grey)),
              ],
            ),
          );
        }
        return Column(
          children: [
            ListPaginationCountBar(total: books.length, unit: '本'),
            Expanded(
              child: Stack(
                children: [
                  LayoutBuilder(
                    builder: (context, constraints) {
                      final cols = _adaptiveCols(
                        constraints.maxWidth,
                        min: isGrid ? 2 : 1,
                        target: isGrid ? 170 : 360,
                        max: isGrid ? 6 : 4,
                      );
                      return MasonryGridView.count(
                        controller: _scrollController,
                        padding: EdgeInsets.only(
                          top: 4,
                          left: 12,
                          right: 12,
                          bottom: 12 + JellyNavBar.contentBottomAvoid,
                        ),
                        crossAxisCount: cols,
                        mainAxisSpacing: 12,
                        crossAxisSpacing: 12,
                        itemCount: min(books.length, _displayCount),
                        itemBuilder: (context, index) {
                          final book = books[index];
                          final selected = widget.selectedIds.contains(book.id);
                          final card = JellyBookCard(
                            book: book,
                            isGrid: isGrid,
                            heroTag: bookCoverHeroTag('fav', book),
                            onTap: widget.isSelecting
                                ? () => widget.onSelect(book.id)
                                : () => _openDetail(book),
                            onLongPress: () => widget.onSelect(book.id),
                          );
                          return StaggeredEntrance(
                            key: ValueKey('book_${book.id}'),
                            index: index,
                            child: Stack(
                              children: [
                                card,
                                if (widget.isSelecting)
                                  Positioned(
                                    top: 4,
                                    right: 4,
                                    child: JellySelectBadge(selected: selected),
                                  ),
                              ],
                            ),
                          );
                        },
                      );
                    },
                  ),
                  if (_showBackToTop && !widget.isSelecting)
                    ListenableBuilder(
                      listenable: SettingsService(),
                      builder: (context, _) {
                        final bottomOffset = SettingsService().navFloating
                            ? JellyNavBar.floatingTotalHeight + 8
                            : 16.0;
                        return Positioned(
                          bottom: bottomOffset,
                          right: 16,
                          child: AnimatedScale(
                            scale: _showBackToTop ? 1.0 : 0.0,
                            duration: const Duration(milliseconds: 200),
                            curve: Curves.easeOut,
                            child: Material(
                              color: JellyTheme.primary,
                              shape: const CircleBorder(),
                              elevation: 4,
                              clipBehavior: Clip.antiAlias,
                              child: InkWell(
                                onTap: _scrollToTop,
                                child: const SizedBox(
                                  width: 44,
                                  height: 44,
                                  child: Icon(
                                    Icons.arrow_upward_rounded,
                                    color: Colors.white,
                                    size: 22,
                                  ),
                                ),
                              ),
                            ),
                          ),
                        );
                      },
                    ),
                ],
              ),
            ),
          ],
        );
      },
    );
  }

  static int _adaptiveCols(
    double width, {
    required int min,
    int max = 6,
    double target = 170,
  }) {
    final available = width - 40;
    var cols = (available / target).floor();
    if (cols < min) cols = min;
    if (cols > max) cols = max;
    return cols;
  }
}
