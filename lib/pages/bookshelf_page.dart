import 'dart:math' show min;
import 'dart:convert';
import 'dart:io';
import 'dart:ui';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'peer_transfer_page.dart';
import '../models/book.dart';
import '../models/bookshelf.dart';
import '../models/comic.dart';
import '../services/book_download_service.dart';
import '../services/book_favorites_service.dart';
import '../services/book_reading_progress_service.dart';
import '../services/bookshelf_service.dart';
import '../source/adapter.dart';
import '../source/source_manager.dart';
import '../services/download_service.dart';
import '../services/reading_progress_service.dart';
import '../services/settings_service.dart';
import '../utils/list_pagination.dart';
import '../theme/jelly_theme.dart';
import '../widgets/jelly_bookshelf_dialog.dart';
import '../widgets/jelly_nav_bar.dart';
import '../widgets/jelly_search_bar.dart';
import '../widgets/jelly_segmented_toggle.dart';
import '../widgets/jelly_select_badge.dart';
import '../widgets/staggered_entrance.dart';
import 'book_detail_page.dart';
import 'book_reader_page.dart';
import 'comic_detail_page.dart';
import 'reader_page.dart';

/// 书架页面
class BookshelfPage extends StatefulWidget {
  final bool isActive;

  /// 是否显示返回按钮（从"我的"页面入口进入时为 true）
  final bool showBackButton;

  const BookshelfPage({
    super.key,
    this.isActive = false,
    this.showBackButton = false,
  });

  @override
  State<BookshelfPage> createState() => _BookshelfPageState();
}

class _BookshelfPageState extends State<BookshelfPage>
    with TickerProviderStateMixin {
  late TabController _tabController;
  String _currentShelfId = BookshelfService.presetReading;
  final ScrollController _comicScrollController = ScrollController();
  final ScrollController _bookScrollController = ScrollController();
  bool _showComicBackToTop = false;
  bool _showBookBackToTop = false;
  int _session = 0;
  bool _hasShownEntrance = false;
  int _comicDisplayCount = ListPagination.pageSize; // 漫画 tab 滚动懒加载条数
  int _bookDisplayCount = ListPagination.pageSize; // 图书 tab 滚动懒加载条数
  final Map<String, GlobalKey> _shelfChipKeys = {};

  // 多选模式
  bool _isSelecting = false;
  final Set<String> _selectedItemIds = {};

  // 搜索浮层
  late final AnimationController _searchAnim;
  final TextEditingController _searchController = TextEditingController();
  String _searchQuery = '';

  @override
  void initState() {
    super.initState();
    final tabs = SettingsService().effectiveContentTabs();
    final initialIdx = min(
      SettingsService().defaultContentTabIndex(),
      tabs.length - 1,
    );
    _tabController = TabController(
      length: tabs.length,
      vsync: this,
      initialIndex: initialIdx,
    );
    SettingsService().addListener(_onContentTabsChanged);
    _comicScrollController.addListener(_onComicScroll);
    _bookScrollController.addListener(_onBookScroll);
    _searchAnim = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 300),
    );
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final shelves = BookshelfService().bookshelves;
      if (shelves.isNotEmpty) {
        setState(() => _currentShelfId = shelves.first.id);
      }
    });
  }

  @override
  void didUpdateWidget(covariant BookshelfPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.isActive && !oldWidget.isActive && !_hasShownEntrance) {
      _hasShownEntrance = true;
      setState(() => _session++);
    }
  }

  @override
  void dispose() {
    SettingsService().removeListener(_onContentTabsChanged);
    _tabController.dispose();
    _comicScrollController.dispose();
    _bookScrollController.dispose();
    _searchAnim.dispose();
    _searchController.dispose();
    super.dispose();
  }

  /// 显示设置变化（跟随导航栏/默认显示/导航栏可见 tab）时，按需重建 TabController
  void _onContentTabsChanged() {
    if (!mounted) return;
    final newLen = SettingsService().effectiveContentTabs().length;
    if (newLen != _tabController.length) {
      final oldIndex = _tabController.index;
      _tabController.dispose();
      _tabController = TabController(
        length: newLen,
        vsync: this,
        initialIndex: min(oldIndex, newLen - 1),
      );
    }
    if (mounted) setState(() {});
  }

  /// 当前 tab 是否为漫画（动态 tab 顺序下不依赖固定 index）
  bool get _isComicTab {
    final tabs = SettingsService().effectiveContentTabs();
    final idx = _tabController.index.clamp(0, tabs.length - 1);
    return tabs[idx] == NavTab.manga;
  }

  /// 当前 tab 的 NavTab
  NavTab get _currentTab {
    final tabs = SettingsService().effectiveContentTabs();
    final idx = _tabController.index.clamp(0, tabs.length - 1);
    return tabs[idx];
  }

  /// 指定 NavTab 在有效 tabs 中的 index（找不到返回 -1）
  int _indexOfTab(NavTab tab) =>
      SettingsService().effectiveContentTabs().indexOf(tab);

  void _onComicScroll() {
    if (!_comicScrollController.hasClients) return;
    final total = BookshelfService().countInShelf(
      _currentShelfId,
      BookshelfItemType.comic,
    );
    if (ListPagination.shouldLoadMore(_comicScrollController) &&
        _comicDisplayCount < total) {
      setState(
        () => _comicDisplayCount = min(
          _comicDisplayCount + ListPagination.pageSize,
          total,
        ),
      );
      return;
    }
    final show = _comicScrollController.position.pixels > 300;
    if (show != _showComicBackToTop) setState(() => _showComicBackToTop = show);
  }

  void _onBookScroll() {
    if (!_bookScrollController.hasClients) return;
    final total = BookshelfService().countInShelf(
      _currentShelfId,
      BookshelfItemType.book,
    );
    if (ListPagination.shouldLoadMore(_bookScrollController) &&
        _bookDisplayCount < total) {
      setState(
        () => _bookDisplayCount = min(
          _bookDisplayCount + ListPagination.pageSize,
          total,
        ),
      );
      return;
    }
    final show = _bookScrollController.position.pixels > 300;
    if (show != _showBookBackToTop) setState(() => _showBookBackToTop = show);
  }

  void _scrollComicToTop() {
    if (_comicScrollController.hasClients) {
      _comicScrollController.animateTo(
        0,
        duration: const Duration(milliseconds: 400),
        curve: Curves.easeOutCubic,
      );
    }
  }

  void _scrollBookToTop() {
    if (_bookScrollController.hasClients) {
      _bookScrollController.animateTo(
        0,
        duration: const Duration(milliseconds: 400),
        curve: Curves.easeOutCubic,
      );
    }
  }

  // ========== 搜索浮层 ==========

  void _openSearch() {
    FocusScope.of(context).unfocus();
    _searchAnim.forward();
  }

  void _closeSearch() {
    _searchAnim.reverse().then((_) {
      if (mounted) {
        _searchController.clear();
        setState(() => _searchQuery = '');
      }
    });
  }

  // ========== 书架管理 ==========

  Future<void> _createShelf() async {
    final controller = TextEditingController();
    final result = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('新建书架'),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: const InputDecoration(hintText: '输入书架名称'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, controller.text),
            child: const Text('创建'),
          ),
        ],
      ),
    );
    if (result != null && result.trim().isNotEmpty) {
      final shelf = await BookshelfService().createBookshelf(result.trim());
      if (shelf != null) {
        setState(() => _currentShelfId = shelf.id);
      } else if (mounted) {
        ScaffoldMessenger.of(context)
          ..hideCurrentSnackBar()
          ..showSnackBar(
            const SnackBar(
              content: Text('书架名称已存在'),
              duration: Duration(seconds: 2),
              behavior: SnackBarBehavior.floating,
            ),
          );
      }
    }
  }

  Future<void> _renameShelf(Bookshelf shelf) async {
    final controller = TextEditingController(text: shelf.name);
    final result = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('重命名书架'),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: const InputDecoration(hintText: '输入新名称'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, controller.text),
            child: const Text('确定'),
          ),
        ],
      ),
    );
    if (result != null && result.trim().isNotEmpty) {
      final ok = await BookshelfService().renameBookshelf(
        shelf.id,
        result.trim(),
      );
      if (!ok && mounted) {
        ScaffoldMessenger.of(context)
          ..hideCurrentSnackBar()
          ..showSnackBar(
            const SnackBar(
              content: Text('书架名称已存在'),
              duration: Duration(seconds: 2),
              behavior: SnackBarBehavior.floating,
            ),
          );
      }
    }
  }

  Future<void> _deleteShelf(Bookshelf shelf) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('删除书架'),
        content: Text('确定删除「${shelf.name}」吗？\n书架内的书籍不会被删除。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            style: TextButton.styleFrom(foregroundColor: Colors.red),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (confirmed == true) {
      final ok = await BookshelfService().deleteBookshelf(shelf.id);
      if (ok) {
        final shelves = BookshelfService().bookshelves;
        if (shelves.isNotEmpty) {
          setState(() => _currentShelfId = shelves.first.id);
        }
      }
    }
  }

  void _showShelfMenu(Bookshelf shelf) {
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (context) {
        final isDark = Theme.of(context).brightness == Brightness.dark;
        return Container(
          decoration: BoxDecoration(
            color: isDark ? const Color(0xFF1E1E3A) : Colors.white,
            borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
          ),
          child: SafeArea(
            top: false,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const SizedBox(height: 12),
                Container(
                  width: 36,
                  height: 4,
                  decoration: BoxDecoration(
                    color: isDark
                        ? Colors.white.withValues(alpha: 0.2)
                        : Colors.black.withValues(alpha: 0.15),
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
                const SizedBox(height: 8),
                ListTile(
                  leading: const Icon(Icons.edit_rounded),
                  title: const Text('重命名'),
                  onTap: () {
                    Navigator.pop(context);
                    _renameShelf(shelf);
                  },
                ),
                if (!shelf.isPreset)
                  ListTile(
                    leading: const Icon(
                      Icons.delete_outline_rounded,
                      color: Colors.red,
                    ),
                    title: const Text(
                      '删除书架',
                      style: TextStyle(color: Colors.red),
                    ),
                    onTap: () {
                      Navigator.pop(context);
                      _deleteShelf(shelf);
                    },
                  ),
                ListTile(
                  leading: const Icon(Icons.close_rounded),
                  title: const Text('取消'),
                  onTap: () => Navigator.pop(context),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  // ========== 左右滑动：优先切书架，到边界切漫画/图书类型 ==========

  // 用 Listener（原始指针事件）检测水平滑动，不参与手势仲裁，
  // 避免与内部纵向 ListView 抢手势导致"要滑两次"。
  Offset? _swipeStart;

  void _onSwipeDown(PointerDownEvent e) {
    _swipeStart = e.position;
  }

  void _onSwipeUp(PointerUpEvent e) {
    _handleSwipeEnd(e.position);
  }

  void _onSwipeCancel(PointerCancelEvent e) {
    _swipeStart = null;
  }

  void _handleSwipeEnd(Offset end) {
    final start = _swipeStart;
    _swipeStart = null;
    if (start == null) return;
    final dx = end.dx - start.dx;
    final dy = end.dy - start.dy;
    // 明显水平为主且超过距离阈值才触发，避免误触纵向滚动/轻点
    if (dx.abs() < 50) return;
    if (dx.abs() <= dy.abs() * 1.3) return;
    if (dx < 0) {
      _swipeNext();
    } else {
      _swipePrev();
    }
  }

  /// 左滑（下一）：切到下一个书架；已是末书架则切到图书 tab
  void _swipeNext() {
    final shelves = _visibleShelves(_currentTab);
    final idx = shelves.indexWhere((s) => s.id == _currentShelfId);
    if (idx >= 0 && idx < shelves.length - 1) {
      _switchShelf(shelves[idx + 1].id);
    } else if (_isComicTab) {
      _switchTab(NavTab.book);
    }
  }

  /// 右滑（上一）：切到上一个书架；已是首书架则切到漫画 tab
  void _swipePrev() {
    final shelves = _visibleShelves(_currentTab);
    final idx = shelves.indexWhere((s) => s.id == _currentShelfId);
    if (idx > 0) {
      _switchShelf(shelves[idx - 1].id);
    } else if (!_isComicTab) {
      _switchTab(NavTab.manga);
    }
  }

  /// 切换漫画/图书 tab：当前书架在新 tab 有书则保持，否则回第一个（避免空）
  void _switchTab(NavTab tab) {
    final idx = _indexOfTab(tab);
    if (idx < 0 || _tabController.index == idx) return;
    if (_isSelecting) {
      _isSelecting = false;
      _selectedItemIds.clear();
    }
    _tabController.animateTo(idx);
    final shelves = _visibleShelves(tab);
    if (shelves.isEmpty) return;
    final newType = tab == NavTab.manga
        ? BookshelfItemType.comic
        : BookshelfItemType.book;
    if (BookshelfService().countInShelf(_currentShelfId, newType) == 0) {
      _switchShelf(shelves.first.id);
    }
  }

  /// 当前 tab 可见的书架列表：漫画 tab 隐藏"本地图书"书架（其内仅 Book 类型）
  List<Bookshelf> _visibleShelves(NavTab tab) {
    final shelves = BookshelfService().bookshelves;
    if (tab == NavTab.manga) {
      return shelves
          .where((s) => s.id != BookshelfService.presetLocal)
          .toList();
    }
    return shelves;
  }

  /// 切换书架并滚动标签栏让当前 chip 可见
  void _switchShelf(String shelfId) {
    setState(() {
      _currentShelfId = shelfId;
      _comicDisplayCount = ListPagination.pageSize;
      _bookDisplayCount = ListPagination.pageSize;
      _isSelecting = false;
      _selectedItemIds.clear();
    });
    _ensureShelfChipVisible(shelfId);
  }

  void _ensureShelfChipVisible(String shelfId) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final ctx = _shelfChipKeys[shelfId]?.currentContext;
      if (ctx != null) {
        Scrollable.ensureVisible(
          ctx,
          alignment: 0.5,
          duration: const Duration(milliseconds: 200),
        );
      }
    });
  }

  GlobalKey _shelfChipKey(String shelfId) =>
      _shelfChipKeys.putIfAbsent(shelfId, () => GlobalKey());

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final contentTabs = SettingsService().effectiveContentTabs();
    final tabSegWidth = (MediaQuery.of(context).size.width * 0.5 - 10) / 2;
    return PopScope(
      canPop: !_isSelecting,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop && _isSelecting) _exitSelection();
      },
      child: Scaffold(
        appBar: widget.showBackButton
            ? AppBar(
                title: const Text('书架'),
                actions: [
                  if (contentTabs.length < 2)
                    Padding(
                      padding: const EdgeInsets.only(right: 8),
                      child: _buildSearchButton(size: 36),
                    ),
                  Padding(
                    padding: const EdgeInsets.only(right: 12),
                    child: _buildImportExportButton(),
                  ),
                ],
              )
            : null,
        body: SafeArea(
          top: !widget.showBackButton,
          bottom: false,
          child: Stack(
            children: [
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // 顶部标题区
                  SizedBox(
                    height: contentTabs.length < 2
                        ? (widget.showBackButton ? 0.0 : 50.0)
                        : (widget.showBackButton ? 70.0 : 105.0),
                    child: Stack(
                      children: [
                        if (!widget.showBackButton)
                          Positioned(
                            top: 6,
                            left: 12,
                            right: 12,
                            child: Row(
                              children: [
                                Padding(
                                  padding: const EdgeInsets.only(left: 4),
                                  child: Text(
                                    '书架',
                                    style: TextStyle(
                                      fontSize: 22,
                                      fontWeight: FontWeight.bold,
                                      color: isDark
                                          ? Colors.white
                                          : JellyTheme.textPrimaryLight,
                                    ),
                                  ),
                                ),
                                const Spacer(),
                                if (contentTabs.length < 2) ...[
                                  _buildSearchButton(size: 36),
                                  const SizedBox(width: 8),
                                ],
                                _buildImportExportButton(),
                              ],
                            ),
                          ),
                        Positioned(
                          top: widget.showBackButton ? 6 : 45,
                          left: 12,
                          right: 12,
                          child: Row(
                            children: [
                              const Spacer(),
                              Builder(
                                builder: (context) {
                                  final tabs = SettingsService()
                                      .effectiveContentTabs();
                                  if (tabs.length < 2) {
                                    return const SizedBox.shrink();
                                  }
                                  return AnimatedBuilder(
                                    animation: _tabController.animation!,
                                    builder: (context, _) =>
                                        JellySegmentedToggle(
                                          index:
                                              _tabController.animation!.value,
                                          onChanged: (i) {
                                            if (i >= 0 && i < tabs.length) {
                                              _switchTab(tabs[i]);
                                            }
                                          },
                                          segmentWidth: tabSegWidth,
                                          segments: tabs
                                              .map(
                                                (t) => JellySegmentData(
                                                  icon: t == NavTab.manga
                                                      ? Icons.palette_rounded
                                                      : Icons.book_rounded,
                                                ),
                                              )
                                              .toList(),
                                        ),
                                  );
                                },
                              ),
                              if (contentTabs.length >= 2) ...[
                                const SizedBox(width: 8),
                                _buildSearchButton(),
                              ],
                              const Spacer(),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                  // 书架分类栏
                  _buildShelfBar(isDark),
                  // 内容区：左右滑优先切书架，书架到边界再切漫画/图书类型
                  Expanded(
                    child: Listener(
                      onPointerDown: _onSwipeDown,
                      onPointerUp: _onSwipeUp,
                      onPointerCancel: _onSwipeCancel,
                      child: TabBarView(
                        controller: _tabController,
                        physics: const NeverScrollableScrollPhysics(),
                        children: SettingsService()
                            .effectiveContentTabs()
                            .map(
                              (t) => t == NavTab.manga
                                  ? _ComicShelfTab(
                                      shelfId: _currentShelfId,
                                      scrollController: _comicScrollController,
                                      showBackToTop: _showComicBackToTop,
                                      onBackToTop: _scrollComicToTop,
                                      session: _session,
                                      displayCount: _comicDisplayCount,
                                      isSelecting: _isSelecting,
                                      selectedIds: _selectedItemIds,
                                      onSelect: _onSelect,
                                    )
                                  : _BookShelfTab(
                                      shelfId: _currentShelfId,
                                      scrollController: _bookScrollController,
                                      showBackToTop: _showBookBackToTop,
                                      onBackToTop: _scrollBookToTop,
                                      session: _session,
                                      displayCount: _bookDisplayCount,
                                      isSelecting: _isSelecting,
                                      selectedIds: _selectedItemIds,
                                      onSelect: _onSelect,
                                    ),
                            )
                            .toList(),
                      ),
                    ),
                  ),
                ],
              ),
              // 搜索浮层
              _buildSearchOverlay(isDark),
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
      ),
    );
  }

  // ========== 多选模式 ==========

  void _onSelect(String itemId) {
    setState(() {
      if (!_isSelecting) {
        _isSelecting = true;
        _selectedItemIds
          ..clear()
          ..add(itemId);
      } else if (_selectedItemIds.contains(itemId)) {
        _selectedItemIds.remove(itemId);
      } else {
        _selectedItemIds.add(itemId);
      }
    });
  }

  void _exitSelection() {
    setState(() {
      _isSelecting = false;
      _selectedItemIds.clear();
    });
  }

  void _selectAll() {
    final type = _isComicTab ? BookshelfItemType.comic : BookshelfItemType.book;
    setState(() {
      _selectedItemIds
        ..clear()
        ..addAll(
          BookshelfService()
              .getItemsInShelf(_currentShelfId, type)
              .map((i) => i.itemId),
        );
    });
  }

  Future<void> _removeSelectedFromShelf() async {
    if (_selectedItemIds.isEmpty) return;
    final type = _isComicTab ? BookshelfItemType.comic : BookshelfItemType.book;
    final count = _selectedItemIds.length;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('移出书架'),
        content: Text('确定将选中的 $count 项移出当前书架？'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('移出'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    for (final itemId in _selectedItemIds.toList()) {
      await BookshelfService().removeFromBookshelf(
        _currentShelfId,
        itemId,
        type,
      );
      if (type == BookshelfItemType.book) {
        await BookDownloadService().cleanupOrphanedImport(itemId);
      }
    }
    if (mounted) _exitSelection();
  }

  Future<void> _moveSelectedToShelf() async {
    if (_selectedItemIds.isEmpty) return;
    final type = _isComicTab ? BookshelfItemType.comic : BookshelfItemType.book;
    final target = await _showBatchMoveDialog();
    if (target == null) return;
    for (final itemId in _selectedItemIds.toList()) {
      final meta = BookshelfService().findItemMeta(itemId, type);
      await BookshelfService().setBookshelvesForItem(
        [target],
        itemId,
        type,
        meta: meta,
      );
    }
    if (mounted) _exitSelection();
  }

  /// 批量移动：选目标书架（单选，禁用当前书架），返回目标 shelfId
  Future<String?> _showBatchMoveDialog() async {
    String? picked;
    return showModalBottomSheet<String>(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      builder: (ctx) {
        final isDark = Theme.of(ctx).brightness == Brightness.dark;
        final textColor = isDark ? Colors.white : Colors.black87;
        return StatefulBuilder(
          builder: (ctx, setState) {
            final shelves = BookshelfService().bookshelves;
            return Container(
              decoration: BoxDecoration(
                color: isDark ? const Color(0xFF1E1E3A) : Colors.white,
                borderRadius: const BorderRadius.vertical(
                  top: Radius.circular(24),
                ),
              ),
              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
              child: SafeArea(
                top: false,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Center(
                      child: Container(
                        width: 36,
                        height: 4,
                        margin: const EdgeInsets.only(bottom: 12),
                        decoration: BoxDecoration(
                          color: Colors.grey.withValues(alpha: 0.3),
                          borderRadius: BorderRadius.circular(2),
                        ),
                      ),
                    ),
                    Text(
                      '移到其他书架',
                      style: TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.bold,
                        color: textColor,
                      ),
                    ),
                    const SizedBox(height: 12),
                    Flexible(
                      child: ListView.builder(
                        shrinkWrap: true,
                        itemCount: shelves.length,
                        itemBuilder: (ctx, i) {
                          final s = shelves[i];
                          final selected = picked == s.id;
                          final disabled = s.id == _currentShelfId;
                          return InkWell(
                            onTap: disabled
                                ? null
                                : () => setState(() => picked = s.id),
                            borderRadius: BorderRadius.circular(12),
                            child: Padding(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 4,
                                vertical: 10,
                              ),
                              child: Row(
                                children: [
                                  Icon(
                                    selected
                                        ? Icons.radio_button_checked_rounded
                                        : Icons.radio_button_unchecked_rounded,
                                    color: selected
                                        ? JellyTheme.primary
                                        : (disabled
                                              ? Colors.grey
                                              : (isDark
                                                    ? Colors.white38
                                                    : Colors.black38)),
                                    size: 22,
                                  ),
                                  const SizedBox(width: 12),
                                  Icon(
                                    s.isPreset
                                        ? Icons.star_border_rounded
                                        : Icons.folder_outlined,
                                    size: 20,
                                    color: isDark
                                        ? Colors.white60
                                        : Colors.black54,
                                  ),
                                  const SizedBox(width: 10),
                                  Expanded(
                                    child: Text(
                                      s.name,
                                      style: TextStyle(
                                        fontSize: 14,
                                        color: disabled
                                            ? Colors.grey
                                            : textColor,
                                      ),
                                    ),
                                  ),
                                  Text(
                                    '${BookshelfService().countInShelf(s.id)}',
                                    style: TextStyle(
                                      fontSize: 12,
                                      color: isDark
                                          ? Colors.white38
                                          : Colors.black38,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          );
                        },
                      ),
                    ),
                    const SizedBox(height: 16),
                    SizedBox(
                      width: double.infinity,
                      child: ElevatedButton(
                        onPressed: picked == null
                            ? null
                            : () => Navigator.pop(ctx, picked),
                        style: ElevatedButton.styleFrom(
                          backgroundColor: JellyTheme.primary,
                          foregroundColor: Colors.white,
                          padding: const EdgeInsets.symmetric(vertical: 12),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(12),
                          ),
                          elevation: 0,
                        ),
                        child: const Text(
                          '确定',
                          style: TextStyle(
                            fontSize: 15,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            );
          },
        );
      },
    );
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
          Flexible(
            child: Text(
              '已选 ${_selectedItemIds.length} 项',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.w600,
                color: isDark ? Colors.white : JellyTheme.textPrimaryLight,
              ),
            ),
          ),
          const SizedBox(width: 8),
          TextButton(onPressed: _selectAll, child: const Text('全选')),
          const SizedBox(width: 4),
          FilledButton.tonal(
            onPressed: _selectedItemIds.isEmpty
                ? null
                : _removeSelectedFromShelf,
            style: FilledButton.styleFrom(
              foregroundColor: Colors.white,
              padding: const EdgeInsets.symmetric(horizontal: 12),
              minimumSize: const Size(0, 40),
            ),
            child: const Icon(Icons.remove_circle_outline_rounded, size: 18),
          ),
          const SizedBox(width: 4),
          FilledButton(
            onPressed: _selectedItemIds.isEmpty ? null : _moveSelectedToShelf,
            style: FilledButton.styleFrom(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              minimumSize: const Size(0, 40),
            ),
            child: const Icon(Icons.swap_horiz_rounded, size: 18),
          ),
          const SizedBox(width: 4),
          IconButton(
            onPressed: _exitSelection,
            icon: const Icon(Icons.close_rounded),
            tooltip: '退出多选',
            visualDensity: VisualDensity.compact,
            constraints: const BoxConstraints(minWidth: 36, minHeight: 36),
            padding: EdgeInsets.zero,
          ),
        ],
      ),
    );
  }

  // ========== 顶部搜索按钮 ==========

  Widget _buildSearchButton({double size = 50}) {
    final iconSize = size <= 40 ? 20.0 : 22.0;
    return Material(
      color: JellyTheme.primary,
      shape: const CircleBorder(),
      elevation: 4,
      shadowColor: JellyTheme.primary.withValues(alpha: 0.4),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: _openSearch,
        child: SizedBox(
          width: size,
          height: size,
          child: Icon(
            Icons.search_rounded,
            color: Colors.white,
            size: iconSize,
          ),
        ),
      ),
    );
  }

  // ========== 导入/导出 ==========

  Widget _buildImportExportButton() {
    return Material(
      color: const Color(0xFFF19841),
      shape: const CircleBorder(),
      elevation: 2,
      shadowColor: const Color(0xFFF19841).withValues(alpha: 0.4),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: _showImportExportMenu,
        child: const SizedBox(
          width: 36,
          height: 36,
          child: Icon(Icons.bolt_rounded, color: Colors.white, size: 20),
        ),
      ),
    );
  }

  void _showImportExportMenu() {
    FocusScope.of(context).unfocus();
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (context) {
        final isDark = Theme.of(context).brightness == Brightness.dark;
        return Container(
          decoration: BoxDecoration(
            color: isDark ? const Color(0xFF1E1E3A) : Colors.white,
            borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
          ),
          child: SafeArea(
            top: false,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const SizedBox(height: 12),
                Container(
                  width: 36,
                  height: 4,
                  decoration: BoxDecoration(
                    color: isDark
                        ? Colors.white.withValues(alpha: 0.2)
                        : Colors.black.withValues(alpha: 0.15),
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
                const SizedBox(height: 8),
                ListTile(
                  leading: Icon(
                    Icons.file_download_outlined,
                    color: JellyTheme.primary,
                  ),
                  title: const Text('导入本地图书'),
                  subtitle: const Text('从本地文件导入 epub/pdf/txt 等图书'),
                  onTap: () {
                    Navigator.pop(context);
                    _importLocalBook();
                  },
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(56, 0, 20, 4),
                  child: Align(
                    alignment: Alignment.centerLeft,
                    child: Text(
                      '导入的图书会加入「本地图书」书架，仅在图书标签下显示，离线可读',
                      style: TextStyle(
                        fontSize: 12,
                        color: isDark ? Colors.white38 : Colors.black38,
                      ),
                    ),
                  ),
                ),
                ListTile(
                  leading: Icon(
                    Icons.upload_outlined,
                    color: JellyTheme.primary,
                  ),
                  title: const Text('传书到电脑'),
                  subtitle: const Text('把书架的书发送到电脑/阅读器'),
                  onTap: () {
                    Navigator.pop(context);
                    Navigator.push(
                      context,
                      MaterialPageRoute(
                        builder: (_) =>
                            const PeerTransferPage(mode: PeerTransferMode.send),
                      ),
                    );
                  },
                ),
                ListTile(
                  leading: Icon(
                    Icons.download_outlined,
                    color: JellyTheme.primary,
                  ),
                  title: const Text('从电脑接收'),
                  subtitle: const Text('接收电脑发来的书，自动入库'),
                  onTap: () {
                    Navigator.pop(context);
                    Navigator.push(
                      context,
                      MaterialPageRoute(
                        builder: (_) => const PeerTransferPage(
                          mode: PeerTransferMode.receive,
                        ),
                      ),
                    );
                  },
                ),
                ListTile(
                  leading: Icon(
                    Icons.close_rounded,
                    color: isDark ? Colors.white70 : JellyTheme.textSecondary,
                  ),
                  title: const Text('取消'),
                  onTap: () => Navigator.pop(context),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  /// 导入本地图书：多选文件 -> 逐本建已完成任务 -> 入"本地图书"书架（Book 类型，固定 id）
  Future<void> _importLocalBook() async {
    final result = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowMultiple: true,
      allowedExtensions: const [
        'epub',
        'pdf',
        'txt',
        'mobi',
        'azw',
        'azw3',
        'fb2',
        'docx',
        'rtf',
      ],
    );
    if (result == null || result.files.isEmpty) return;
    if (!mounted) return;

    // 预取 root navigator：loading 挂在它上面，pop 不依赖页面 context
    final rootNav = Navigator.of(context, rootNavigator: true);
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (_) => const PopScope(
        canPop: false,
        child: Center(
          child: CircularProgressIndicator(color: JellyTheme.primary),
        ),
      ),
    );

    final svc = BookDownloadService();
    final seen = <String>{}; // 本次选择内已处理的书名+扩展名，防同批重名重复入
    final imported =
        <({String bookId, String title, String ext, String? cover})>[];
    var skipped = 0; // 已在书架或同批重名跳过
    var failed = 0;
    try {
      for (final f in result.files) {
        final path = f.path;
        if (path == null) {
          failed++;
          continue;
        }
        final fileName = f.name;
        final dot = fileName.lastIndexOf('.');
        final title = dot > 0 ? fileName.substring(0, dot) : fileName;
        final ext = dot > 0 ? fileName.substring(dot + 1) : 'epub';
        final key = '${title.toLowerCase()}:${ext.toLowerCase()}';
        if (seen.contains(key)) {
          skipped++;
          continue;
        }
        seen.add(key);
        // 去重：同名同扩展名的导入书已在书架则跳过
        final dup = svc.tasks.values.any(
          (t) =>
              t.isLocalImport &&
              t.title.toLowerCase() == title.toLowerCase() &&
              t.extension == ext.toLowerCase(),
        );
        if (dup) {
          skipped++;
          continue;
        }
        final bookId = await svc.importLocalFile(
          File(path),
          title: title,
          extension: ext,
        );
        if (bookId == null) {
          failed++;
          continue;
        }
        imported.add((
          bookId: bookId,
          title: title,
          ext: ext,
          cover: svc.task(bookId)?.cover,
        ));
      }
    } finally {
      rootNav.pop(); // 关 loading
    }
    if (!mounted) return;

    // 有导入成功：统一入"本地图书"书架（固定 id，仅图书 tab 可见），类型为 Book
    if (imported.isNotEmpty) {
      final shelf = await BookshelfService().ensureLocalBookshelf();
      for (final b in imported) {
        final meta = jsonEncode(
          Book(
            id: b.bookId,
            hash: '',
            title: b.title,
            cover: b.cover,
            extension: b.ext,
          ).toJson(),
        );
        await BookshelfService().addToBookshelf(
          shelf.id,
          b.bookId,
          BookshelfItemType.book,
          meta: meta,
        );
      }
      // 切到图书 tab 并选中"本地图书"书架，让用户立刻看到导入结果
      final bookIdx = _indexOfTab(NavTab.book);
      if (bookIdx >= 0 && _tabController.index != bookIdx) {
        _tabController.animateTo(bookIdx);
      }
      setState(() => _currentShelfId = shelf.id);
      _ensureShelfChipVisible(shelf.id);
    }

    // 反馈：单本保留书名，多本按数量；跳过/失败追加说明
    final parts = <String>[];
    if (imported.isEmpty) {
      if (skipped > 0) parts.add('$skipped 本已在书架');
      if (failed > 0) parts.add('$failed 本导入失败');
      if (parts.isEmpty) parts.add('导入失败');
    } else {
      parts.add(
        imported.length == 1
            ? '已导入「${imported.first.title}」'
            : '已导入 ${imported.length} 本',
      );
      if (skipped > 0) parts.add('$skipped 本已在书架');
      if (failed > 0) parts.add('$failed 本导入失败');
    }
    if (mounted) {
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(
          SnackBar(
            content: Text(parts.join('，')),
            duration: const Duration(seconds: 2),
            behavior: SnackBarBehavior.floating,
          ),
        );
    }
  }

  // ========== 搜索浮层 ==========

  Widget _buildSearchOverlay(bool isDark) {
    return Positioned.fill(
      child: AnimatedBuilder(
        animation: _searchAnim,
        builder: (context, child) {
          if (_searchAnim.isDismissed) return const SizedBox.shrink();
          return child!;
        },
        child: Stack(
          children: [
            // 模糊蒙版
            Positioned.fill(
              child: GestureDetector(
                onTap: _closeSearch,
                behavior: HitTestBehavior.opaque,
                child: FadeTransition(
                  opacity: _searchAnim,
                  child: BackdropFilter(
                    filter: ImageFilter.blur(sigmaX: 12, sigmaY: 12),
                    child: Container(
                      color: Colors.black.withValues(alpha: 0.2),
                    ),
                  ),
                ),
              ),
            ),
            // 搜索内容
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
                  child: _buildSearchContent(isDark),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildSearchContent(bool isDark) {
    // 用页面级 context（State 的 context）做后续导航：item 的 context 会在
    // _closeSearch() 清空查询后随列表重建被销毁，导致异步打开阅读器时 mounted 检查失败。
    final pageContext = context;
    final q = _searchQuery.trim().toLowerCase();
    final comicResults = <Comic>[];
    final bookResults = <Book>[];

    if (q.isNotEmpty) {
      // 搜索书架条目：按与书架 Tab 相同方式解析（收藏夹优先，meta 快照兜底），
      // 按 itemId 去重，保证"书架上能看到的就能搜到"
      final seenComic = <String>{};
      final seenBook = <String>{};
      for (final item in BookshelfService().items) {
        if (item.type == BookshelfItemType.comic) {
          if (!seenComic.add(item.itemId)) continue;
          Comic? comic;
          if (item.meta != null) {
            try {
              comic = Comic.fromJson(
                jsonDecode(item.meta!) as Map<String, dynamic>,
              );
            } catch (_) {}
          }
          if (comic == null) continue;
          final match =
              comic.title.toLowerCase().contains(q) ||
              (comic.alias ?? '').toLowerCase().contains(q) ||
              (comic.author ?? '').toLowerCase().contains(q);
          if (match) comicResults.add(comic);
        } else {
          if (!seenBook.add(item.itemId)) continue;
          Book? book;
          try {
            book = BookFavoritesService().books.firstWhere(
              (b) => b.id == item.itemId,
            );
          } catch (_) {}
          if (book == null && item.meta != null) {
            try {
              book = Book.fromJson(
                jsonDecode(item.meta!) as Map<String, dynamic>,
              );
            } catch (_) {}
          }
          if (book == null) continue;
          final match =
              book.title.toLowerCase().contains(q) ||
              (book.author ?? '').toLowerCase().contains(q);
          if (match) bookResults.add(book);
        }
      }
    }

    // 交错合并结果（漫画一本、图书一本交替）
    final mixed = <dynamic>[];
    final ci = comicResults.iterator;
    final bi = bookResults.iterator;
    while (ci.moveNext()) {
      mixed.add(ci.current);
      if (bi.moveNext()) mixed.add(bi.current);
    }
    while (bi.moveNext()) {
      mixed.add(bi.current);
    }

    final hasQuery = q.isNotEmpty;
    final tooMany = mixed.length > 10;
    final display = tooMany ? mixed.sublist(0, 10) : mixed;

    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          JellySearchBar(
            controller: _searchController,
            hintText: '搜索书架',
            autofocus: true,
            onChanged: (v) => setState(() => _searchQuery = v),
            onCleared: () => setState(() => _searchQuery = ''),
          ),
          const SizedBox(height: 12),
          if (hasQuery && display.isEmpty)
            _buildSearchEmpty(isDark)
          else if (hasQuery)
            SizedBox(
              height: MediaQuery.of(context).size.height * 0.4,
              child: Material(
                color: isDark ? const Color(0xFF252542) : Colors.white,
                borderRadius: BorderRadius.circular(20),
                clipBehavior: Clip.antiAlias,
                child: ListView.builder(
                  padding: const EdgeInsets.symmetric(vertical: 6),
                  itemCount: display.length + (tooMany ? 1 : 0),
                  itemBuilder: (context, index) {
                    if (tooMany && index == display.length) {
                      return Padding(
                        padding: const EdgeInsets.symmetric(
                          vertical: 10,
                          horizontal: 16,
                        ),
                        child: Text(
                          '仅显示前 10 条，继续输入缩小范围',
                          style: TextStyle(
                            fontSize: 12,
                            color: isDark ? Colors.white38 : Colors.black38,
                          ),
                          textAlign: TextAlign.center,
                        ),
                      );
                    }
                    final item = display[index];
                    if (item is Comic) {
                      return _SearchComicTile(
                        comic: item,
                        // 点击行为与书架漫画一致：已下载直接读、未下载弹同样的对话框
                        onTap: () {
                          _closeSearch();
                          _ComicShelfTab._onTapComic(pageContext, item);
                        },
                      );
                    } else if (item is Book) {
                      return _SearchBookTile(
                        book: item,
                        // 点击行为与书架图书一致：已下载直接续读、未下载弹同样的对话框
                        onTap: () {
                          _closeSearch();
                          _BookShelfTab._onTap(pageContext, item);
                        },
                      );
                    }
                    return const SizedBox.shrink();
                  },
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildSearchEmpty(bool isDark) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(vertical: 32),
      decoration: BoxDecoration(
        color: isDark ? const Color(0xFF252542) : Colors.white,
        borderRadius: BorderRadius.circular(20),
      ),
      child: Column(
        children: [
          Icon(
            Icons.search_off_rounded,
            size: 48,
            color: isDark ? Colors.white38 : Colors.black26,
          ),
          const SizedBox(height: 12),
          Text(
            '没有找到相关书籍',
            style: TextStyle(
              color: isDark ? Colors.white54 : Colors.black45,
              fontSize: 14,
            ),
          ),
        ],
      ),
    );
  }

  // ========== 书架分类栏 ==========

  /// 预置"已下载的书"书架显示为"已下载"，其余用书架名
  String _shelfDisplayName(Bookshelf shelf, BookshelfItemType currentType) {
    if (shelf.id == BookshelfService.presetDownloaded) {
      return '已下载';
    }
    return shelf.name;
  }

  Widget _buildShelfBar(bool isDark) {
    return ListenableBuilder(
      listenable: Listenable.merge([BookshelfService(), _tabController]),
      builder: (context, _) {
        final shelves = _visibleShelves(_currentTab);
        final currentType = _isComicTab
            ? BookshelfItemType.comic
            : BookshelfItemType.book;

        // 先构建所有 chip 子元素
        final chips = <Widget>[
          for (int i = 0; i < shelves.length; i++)
            _buildShelfChip(shelves[i], currentType, isDark),
          _buildAddChip(isDark),
        ];

        // 用 IntrinsicWidth 测出内容总宽度，判断是否需要滚动
        return Container(
          height: 34,
          margin: const EdgeInsets.only(bottom: 8),
          child: LayoutBuilder(
            builder: (context, constraints) {
              // 计算内容总宽度（粗略估算用于判断）
              // 每个 chip 间距 8，最后一个不加
              const chipPadding = 24.0; // horizontal 12*2
              const addChipPadding = 20.0; // horizontal 10*2
              const spacing = 8.0;
              const textStyle = TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w600,
              );
              const addTextStyle = TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w600,
              );

              double totalWidth = 0;
              for (int i = 0; i < shelves.length; i++) {
                final shelf = shelves[i];
                final displayName = _shelfDisplayName(shelf, currentType);
                final count = BookshelfService().countInShelf(
                  shelf.id,
                  currentType,
                );
                final textPainter = TextPainter(
                  text: TextSpan(text: displayName, style: textStyle),
                  textDirection: TextDirection.ltr,
                )..layout();
                final numPainter = TextPainter(
                  text: TextSpan(text: '$count', style: textStyle),
                  textDirection: TextDirection.ltr,
                )..layout();
                totalWidth +=
                    chipPadding + textPainter.width + 4 + numPainter.width;
                if (i < shelves.length) totalWidth += spacing;
              }
              // 新建按钮
              final addTextPainter = TextPainter(
                text: const TextSpan(text: '新建', style: addTextStyle),
                textDirection: TextDirection.ltr,
              )..layout();
              totalWidth += addChipPadding + 14 + 2 + addTextPainter.width + 16;

              final scrollView = SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: Row(mainAxisSize: MainAxisSize.min, children: chips),
              );

              if (totalWidth <= constraints.maxWidth - 32) {
                // 内容小于宽度 → 居中
                return Center(child: scrollView);
              }
              // 内容超出 → 正常横向滚动
              return scrollView;
            },
          ),
        );
      },
    );
  }

  Widget _buildShelfChip(
    Bookshelf shelf,
    BookshelfItemType currentType,
    bool isDark,
  ) {
    final selected = shelf.id == _currentShelfId;
    final count = BookshelfService().countInShelf(shelf.id, currentType);
    return Padding(
      key: _shelfChipKey(shelf.id),
      padding: const EdgeInsets.only(right: 8),
      child: GestureDetector(
        onTap: () => _switchShelf(shelf.id),
        onLongPress: () => _showShelfMenu(shelf),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 200),
          curve: Curves.easeOutCubic,
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
          decoration: BoxDecoration(
            color: selected
                ? JellyTheme.primary
                : (isDark ? const Color(0xFF2D2D4A) : Colors.white),
            borderRadius: BorderRadius.circular(16),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.05),
                blurRadius: 6,
                offset: const Offset(0, 2),
              ),
            ],
          ),
          alignment: Alignment.center,
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                _shelfDisplayName(shelf, currentType),
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  color: selected
                      ? Colors.white
                      : (isDark ? Colors.white70 : JellyTheme.textSecondary),
                ),
              ),
              const SizedBox(width: 4),
              Text(
                '$count',
                style: TextStyle(
                  fontSize: 10,
                  color: selected
                      ? Colors.white.withValues(alpha: 0.7)
                      : (isDark
                            ? Colors.white38
                            : JellyTheme.textSecondary.withValues(alpha: 0.7)),
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildAddChip(bool isDark) {
    return Padding(
      padding: const EdgeInsets.only(right: 8),
      child: GestureDetector(
        onTap: _createShelf,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
          decoration: BoxDecoration(
            color: isDark ? const Color(0xFF2D2D4A) : Colors.white,
            borderRadius: BorderRadius.circular(16),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.05),
                blurRadius: 6,
                offset: const Offset(0, 2),
              ),
            ],
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                Icons.add_rounded,
                size: 14,
                color: isDark ? Colors.white70 : JellyTheme.textSecondary,
              ),
              const SizedBox(width: 2),
              Text(
                '新建',
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  color: isDark ? Colors.white70 : JellyTheme.textSecondary,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ============================================================
// 搜索结果条目
// ============================================================
class _SearchComicTile extends StatelessWidget {
  final Comic comic;
  final VoidCallback onTap;

  const _SearchComicTile({required this.comic, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return ListTile(
      onTap: onTap,
      leading: Container(
        width: 36,
        height: 48,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(6),
          color: isDark ? Colors.white10 : Colors.black12,
        ),
        clipBehavior: Clip.antiAlias,
        child: CachedNetworkImage(
          imageUrl: comic.cover,
          httpHeaders: coverHeaders(comic.sourceId),
          fit: BoxFit.cover,
          placeholder: (_, __) => const SizedBox.shrink(),
          errorWidget: (_, __, ___) =>
              const Icon(Icons.palette_rounded, size: 20, color: Colors.grey),
        ),
      ),
      title: Text(
        comic.title,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(
          fontSize: 14,
          fontWeight: FontWeight.w600,
          color: isDark ? Colors.white : JellyTheme.textPrimaryLight,
        ),
      ),
      subtitle: Text(
        comic.author ?? '',
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(
          fontSize: 12,
          color: isDark ? Colors.white54 : JellyTheme.textSecondary,
        ),
      ),
      trailing: Icon(
        Icons.palette_rounded,
        size: 16,
        color: JellyTheme.primary.withValues(alpha: 0.6),
      ),
    );
  }
}

class _SearchBookTile extends StatelessWidget {
  final Book book;
  final VoidCallback onTap;

  const _SearchBookTile({required this.book, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return ListTile(
      onTap: onTap,
      leading: Container(
        width: 36,
        height: 48,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(6),
          color: isDark ? Colors.white10 : Colors.black12,
        ),
        clipBehavior: Clip.antiAlias,
        child: Image.network(
          book.cover ?? '',
          fit: BoxFit.cover,
          errorBuilder: (_, __, ___) =>
              const Icon(Icons.book_rounded, size: 20, color: Colors.grey),
        ),
      ),
      title: Text(
        book.title,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(
          fontSize: 14,
          fontWeight: FontWeight.w600,
          color: isDark ? Colors.white : JellyTheme.textPrimaryLight,
        ),
      ),
      subtitle: Text(
        book.author ?? '',
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(
          fontSize: 12,
          color: isDark ? Colors.white54 : JellyTheme.textSecondary,
        ),
      ),
      trailing: Icon(
        Icons.book_rounded,
        size: 16,
        color: JellyTheme.primary.withValues(alpha: 0.6),
      ),
    );
  }
}

// ============================================================
// 漫画书架 Tab
// ============================================================
/// 书架漫画点击未下载时的弹窗选择
enum _ComicReadChoice { cancel, download, readOnline }

class _ComicShelfTab extends StatelessWidget {
  final String shelfId;
  final ScrollController scrollController;
  final bool showBackToTop;
  final VoidCallback onBackToTop;
  final int session;
  final int displayCount;
  final bool isSelecting;
  final Set<String> selectedIds;
  final ValueChanged<String> onSelect;

  const _ComicShelfTab({
    required this.shelfId,
    required this.scrollController,
    required this.showBackToTop,
    required this.onBackToTop,
    required this.session,
    required this.displayCount,
    this.isSelecting = false,
    this.selectedIds = const {},
    required this.onSelect,
  });

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: Listenable.merge([
        BookshelfService(),
        ReadingProgressService(),
      ]),
      builder: (context, _) {
        final items = BookshelfService().getItemsInShelf(
          shelfId,
          BookshelfItemType.comic,
        );
        // "正在读"：排序键取"加入书架时间"与"最近阅读时间"的较大者倒序
        // --新移入(无进度)用 addedAt 兜底排到顶部；有进度按最近阅读归位(继续阅读仍上浮)
        if (shelfId == BookshelfService.presetReading) {
          items.sort((a, b) {
            final ra =
                ReadingProgressService().getProgress(a.itemId)?.updatedAt ?? 0;
            final rb =
                ReadingProgressService().getProgress(b.itemId)?.updatedAt ?? 0;
            final ka = a.addedAt > ra ? a.addedAt : ra;
            final kb = b.addedAt > rb ? b.addedAt : rb;
            return kb.compareTo(ka);
          });
        }
        final entries = <_ShelfEntry>[];
        var i = 0;
        for (final item in items.take(displayCount)) {
          // 只读条目 meta 快照（与收藏解耦）；无快照则跳过
          Comic? comic;
          if (item.meta != null) {
            try {
              comic = Comic.fromJson(
                jsonDecode(item.meta!) as Map<String, dynamic>,
              );
            } catch (_) {}
          }
          if (comic != null) {
            final c = comic;
            final rp = ReadingProgressService().getProgress(c.pathWord);
            // 进度统一为"已读 N 话"文字（不依赖 totalChapters，与下载/在线无关）
            final double? progress;
            final String? progressLabel;
            if (rp != null && rp.seenChapterIds.isNotEmpty) {
              progress = null;
              // 已读话数=续读位置（读到第几话）；旧数据无 lastChapterIndex 时回退累计已读章节数
              final readCount = rp.lastChapterIndex >= 0
                  ? rp.lastChapterIndex + 1
                  : rp.seenChapterIds.length;
              progressLabel = '已读 $readCount 话';
            } else {
              progress = null;
              progressLabel = null;
            }
            // 漫画源角标：优先用书架快照里的漫画源（手动加入书架即带源），
            // 下载记录兜底（旧数据 meta 无 sourceId 时）；两者都无则不显示
            final sourceId =
                c.sourceId ?? DownloadService().sourceIdForComic(c.pathWord);
            final sourceLabel = sourceId == null
                ? null
                : SourceManager().getSource(sourceId)?.name;
            entries.add(
              _ShelfEntry(
                id: c.id,
                itemId: item.itemId,
                coverUrl: c.cover,
                title: c.title,
                subtitle: c.author ?? '',
                type: BookshelfItemType.comic,
                onTap: () => _onTapComic(context, c),
                index: i,
                meta: item.meta,
                progress: progress,
                progressLabel: progressLabel,
                sourceLabel: sourceLabel,
                sourceId: sourceId,
              ),
            );
          }
          i++;
        }
        if (entries.isEmpty) {
          return _buildEmpty(context, '还没有漫画', Icons.palette_rounded);
        }
        return _buildShelfContent(
          entries: entries,
          scrollController: scrollController,
          showBackToTop: showBackToTop,
          onBackToTop: onBackToTop,
          session: session,
          onLongPress: (e) => _showShelfItemMenu(context, shelfId, e),
          isSelecting: isSelecting,
          selectedIds: selectedIds,
          onSelect: onSelect,
        );
      },
    );
  }

  static Future<void> _onTapComic(BuildContext context, Comic comic) async {
    final downloaded = DownloadService().downloadedChapters(comic.pathWord);
    final total = comic.totalChapters;
    debugPrint(
      '[bookshelf] _onTapComic: title=${comic.title}, pathWord=${comic.pathWord}, '
      'downloaded=${downloaded.length}, totalChapters=$total',
    );

    // 1) 完全没下载：弹窗 在线阅读 / 下载（进详情页）
    if (downloaded.isEmpty) {
      debugPrint('[bookshelf] -> 分支1: 无下载，弹窗');
      final choice = await showDialog<_ComicReadChoice>(
        context: context,
        builder: (ctx) => AlertDialog(
          content: Text('《${comic.title}》尚未下载，是否在线阅读或前往下载？'),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, _ComicReadChoice.cancel),
              child: const Text('取消'),
            ),
            TextButton(
              onPressed: () => Navigator.pop(ctx, _ComicReadChoice.download),
              child: const Text('下载'),
            ),
            TextButton(
              onPressed: () => Navigator.pop(ctx, _ComicReadChoice.readOnline),
              style: TextButton.styleFrom(foregroundColor: JellyTheme.primary),
              child: const Text('在线阅读'),
            ),
          ],
        ),
      );
      if (choice != _ComicReadChoice.readOnline) {
        if (choice == _ComicReadChoice.download) {
          if (!context.mounted) return;
          Navigator.push(
            context,
            MaterialPageRoute(
              builder: (_) => ComicDetailPage(
                comic: comic,
                heroTag: 'bookshelf_comic_${comic.id}',
              ),
            ),
          );
        }
        return;
      }
      if (!context.mounted) return;
      await _openReaderDirectly(context, comic);
      return;
    }

    // 2) 有下载但未全部下载完（total 已知且 downloaded < total）：询问是否在线
    if (total != null && total > 0 && downloaded.length < total) {
      debugPrint('[bookshelf] -> 分支2: 未全下完（${downloaded.length}/$total），弹窗询问');
      final online = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          content: Text(
            '检测到《${comic.title}》章节未全部下载（已下载 ${downloaded.length}/$total 话），是否在线阅读？',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('离线阅读已下载'),
            ),
            TextButton(
              onPressed: () => Navigator.pop(ctx, true),
              style: TextButton.styleFrom(foregroundColor: JellyTheme.primary),
              child: const Text('在线阅读'),
            ),
          ],
        ),
      );
      debugPrint('[bookshelf] 分支2 弹窗结果 online=$online');
      if (online == true) {
        if (!context.mounted) return;
        await _openReaderDirectly(context, comic);
        return;
      }
      if (online == false) {
        _readOffline(context, comic);
        return;
      }
      // null：点弹窗外部 dismiss，取消，不进入阅读
      return;
    }

    // 3) 全部下载完 或 total 缺失：直接离线阅读
    debugPrint(
      '[bookshelf] -> 分支3: 离线读（全下完或total缺失） downloaded=${downloaded.length}, total=$total',
    );
    _readOffline(context, comic);
  }

  /// 离线阅读已下载章节（复用下载记录页逻辑：续读章节或第一章，不拉详情、不耗流量）
  static void _readOffline(BuildContext context, Comic comic) {
    final chapters = DownloadService().downloadedChapters(comic.pathWord);
    if (chapters.isEmpty) return;
    var initialPage = 0;
    var start = chapters.first;
    final progress = ReadingProgressService().getProgress(comic.pathWord);
    if (progress != null) {
      final idx = chapters.indexWhere((c) => c.id == progress.lastChapterId);
      if (idx >= 0) {
        start = chapters[idx];
        initialPage = progress.lastPageIndex;
      }
    }
    final group = ChapterGroup(
      id: 'default',
      name: '默认',
      count: chapters.length,
      chapters: chapters,
    );
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => ReaderPage(
          comic: comic,
          chapter: start,
          groups: [group],
          initialPage: initialPage,
        ),
      ),
    );
  }

  /// 拉详情+章节分组后直接进阅读器（续读章节或第一章）
  static Future<void> _openReaderDirectly(
    BuildContext context,
    Comic comic,
  ) async {
    // 预先取 root navigator：loading 挂在它上面，后续 pop 不依赖页面 context
    final rootNav = Navigator.of(context, rootNavigator: true);
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (_) => const PopScope(
        canPop: false,
        child: Center(
          child: CircularProgressIndicator(color: JellyTheme.primary),
        ),
      ),
    );
    try {
      // 优先用漫画自身所属源（书架含多源漫画，当前选中源未必匹配）；
      // 旧数据无 sourceId 时兜底当前源
      final source = (comic.sourceId != null && comic.sourceId!.isNotEmpty)
          ? (SourceManager().getSource(comic.sourceId!) ??
                SourceManager().current)
          : SourceManager().current;
      final details = await source.getMangaDetailsAndChapters(
        comicToCManga(comic, source.id),
      );
      final result = (
        comic: cmangaToComic(details.manga),
        groups: cchaptersToGroups(details.chapters),
      );
      rootNav.pop(); // 关 loading
      if (!context.mounted) return;
      final groups = result.groups;
      // 章节按源站原始 order 排序，方向由源决定，统一「第1话在前」
      for (final g in groups) {
        g.chapters.sort(
          (a, b) =>
              chapterCompare(a.order, b.order, source.chapterOrderDescending),
        );
      }
      // 起始章节：续读章节；无记录则第一章（order 最小）
      ComicChapter? start;
      var initialPage = 0;
      final rp = ReadingProgressService().getProgress(comic.pathWord);
      if (rp != null) {
        outer:
        for (final g in groups) {
          for (final ch in g.chapters) {
            if (ch.id == rp.lastChapterId) {
              start = ch;
              initialPage = rp.lastPageIndex;
              break outer;
            }
          }
        }
      }
      start ??= _firstChapter(groups);
      if (start == null) {
        if (!context.mounted) return;
        ScaffoldMessenger.of(context)
          ..hideCurrentSnackBar()
          ..showSnackBar(
            const SnackBar(
              content: Text('暂无可读章节'),
              duration: Duration(seconds: 2),
              behavior: SnackBarBehavior.floating,
            ),
          );
        return;
      }
      final startChapter = start;
      if (!context.mounted) return;
      await Navigator.push(
        context,
        MaterialPageRoute(
          builder: (_) => ReaderPage(
            comic: comic,
            chapter: startChapter,
            groups: groups,
            initialPage: initialPage,
          ),
        ),
      );
    } catch (e) {
      rootNav.pop(); // 关 loading
      if (!context.mounted) return;
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(
          SnackBar(
            content: Text('加载失败: $e'),
            duration: const Duration(seconds: 2),
            behavior: SnackBarBehavior.floating,
          ),
        );
    }
  }

  /// 排序后首个非空分组的第一章（与详情页默认显示的第一章一致）。
  /// 不按 order 数值取最小，因为 descending 源（order 大者=第1话）取最小会落到最后一话。
  static ComicChapter? _firstChapter(List<ChapterGroup> groups) {
    for (final g in groups) {
      if (g.chapters.isNotEmpty) return g.chapters.first;
    }
    return null;
  }
}

// ============================================================
// 图书书架 Tab
// ============================================================
class _BookShelfTab extends StatelessWidget {
  final String shelfId;
  final ScrollController scrollController;
  final bool showBackToTop;
  final VoidCallback onBackToTop;
  final int session;
  final int displayCount;
  final bool isSelecting;
  final Set<String> selectedIds;
  final ValueChanged<String> onSelect;

  const _BookShelfTab({
    required this.shelfId,
    required this.scrollController,
    required this.showBackToTop,
    required this.onBackToTop,
    required this.session,
    required this.displayCount,
    this.isSelecting = false,
    this.selectedIds = const {},
    required this.onSelect,
  });

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: Listenable.merge([
        BookshelfService(),
        BookFavoritesService(),
        BookReadingProgressService(),
      ]),
      builder: (context, _) {
        final items = BookshelfService().getItemsInShelf(
          shelfId,
          BookshelfItemType.book,
        );
        // "正在读"：排序键取"加入书架时间"与"最近阅读时间"的较大者倒序
        // --新移入(无进度)用 addedAt 兜底排到顶部；有进度按最近阅读归位(继续阅读仍上浮)
        if (shelfId == BookshelfService.presetReading) {
          items.sort((a, b) {
            final ra =
                BookReadingProgressService().getProgress(a.itemId)?.updatedAt ??
                0;
            final rb =
                BookReadingProgressService().getProgress(b.itemId)?.updatedAt ??
                0;
            final ka = a.addedAt > ra ? a.addedAt : ra;
            final kb = b.addedAt > rb ? b.addedAt : rb;
            return kb.compareTo(ka);
          });
        }
        // 建 id -> Book 索引，消除每项 firstWhere 的 O(n×m)
        final bookMap = {for (final b in BookFavoritesService().books) b.id: b};
        final entries = <_ShelfEntry>[];
        var i = 0;
        for (final item in items.take(displayCount)) {
          // 优先从收藏夹解析（完整数据），否则用条目自带快照兜底
          Book? book = bookMap[item.itemId];
          if (book == null && item.meta != null) {
            try {
              book = Book.fromJson(
                jsonDecode(item.meta!) as Map<String, dynamic>,
              );
            } catch (_) {}
          }
          if (book != null) {
            final b = book;
            final rp = BookReadingProgressService().getProgress(b.id);
            final progress = (rp != null && rp.pageTotal > 0)
                ? ((rp.pageIndex + 1) / rp.pageTotal).clamp(0.0, 1.0)
                : null;
            entries.add(
              _ShelfEntry(
                id: b.id,
                itemId: item.itemId,
                coverUrl: b.cover ?? '',
                title: b.title,
                subtitle: b.author ?? '',
                type: BookshelfItemType.book,
                onTap: () => _onTap(context, b),
                index: i,
                meta: item.meta,
                progress: progress,
                formatLabel: b.extension?.trim().toUpperCase(),
              ),
            );
          }
          i++;
        }
        if (entries.isEmpty) {
          return _buildEmpty(context, '还没有图书', Icons.book_rounded);
        }
        return _buildShelfContent(
          entries: entries,
          scrollController: scrollController,
          showBackToTop: showBackToTop,
          onBackToTop: onBackToTop,
          session: session,
          onLongPress: (e) => _showShelfItemMenu(context, shelfId, e),
          isSelecting: isSelecting,
          selectedIds: selectedIds,
          onSelect: onSelect,
        );
      },
    );
  }

  static Future<void> _onTap(BuildContext context, Book book) async {
    final task = BookDownloadService().task(book.id);
    if (task != null && task.status == BookDownloadStatus.completed) {
      // 已下载：直接续读（阅读器内部自动定位续读点）
      await BookReaderPage.open(context, task);
      return;
    }
    if (task == null) {
      // 未下载：先提示确认，再进详情页下载
      final ok = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          content: const Text('该书尚未下载，是否前往下载？'),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('取消'),
            ),
            TextButton(
              onPressed: () => Navigator.pop(ctx, true),
              style: TextButton.styleFrom(foregroundColor: JellyTheme.primary),
              child: const Text('前往下载'),
            ),
          ],
        ),
      );
      if (ok != true) return;
    }
    // 下载中/失败/暂停 或 已确认前往下载：进详情页
    if (!context.mounted) return;
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) =>
            BookDetailPage(book: book, heroTag: 'bookshelf_book_${book.id}'),
      ),
    );
  }
}

// ============================================================
// 书架书本卡片（竖立书本样式）
// ============================================================
/// 书架条目数据（封面 + 书名/作者 + 点击/长按）
class _ShelfEntry {
  final String id;
  final String itemId; // 书架条目 ID（漫画=pathWord，图书=id），用于移出/移动
  final String coverUrl;
  final String title;
  final String subtitle;
  final BookshelfItemType type;
  final VoidCallback onTap;
  final int index;
  final String? meta; // 元数据快照，移动时透传保持可显示
  final double? progress; // 阅读进度 0~1，null 表示无
  final String? progressLabel; // 无下载但在线阅读时的文字徽标
  final String? formatLabel; // 图书格式角标（EPUB/MOBI/PDF…），漫画为 null
  final String? sourceLabel; // 漫画下载源名角标（如「拷贝漫画」），图书/未下载为 null
  final String? sourceId; // 漫画所属源 id（封面防盗链头用），图书为 null

  _ShelfEntry({
    required this.id,
    required this.itemId,
    required this.coverUrl,
    required this.title,
    required this.subtitle,
    required this.type,
    required this.onTap,
    required this.index,
    this.meta,
    this.progress,
    this.progressLabel,
    this.formatLabel,
    this.sourceLabel,
    this.sourceId,
  });
}

/// 一层书架：封面行 + 架板 + 书名/作者行
class _BookshelfRow extends StatelessWidget {
  final double cellWidth;
  final double spacing;
  final bool isDark;
  final List<_ShelfEntry> entries;
  final int session;
  final void Function(_ShelfEntry) onLongPress;
  final bool isSelecting;
  final Set<String> selectedIds;
  final ValueChanged<String> onSelect;

  const _BookshelfRow({
    required this.cellWidth,
    required this.spacing,
    required this.isDark,
    required this.entries,
    required this.session,
    required this.onLongPress,
    this.isSelecting = false,
    this.selectedIds = const {},
    required this.onSelect,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // 封面行（底部对齐，立在架板上）
        Row(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: _coverSlots(),
        ),
        const SizedBox(height: 4), // 书与架板间距，阴影投在架上
        _ShelfBoard(isDark: isDark),
        const SizedBox(height: 6),
        // 书名/作者行（架板下）
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: _captionSlots(),
        ),
        const SizedBox(height: 20),
      ],
    );
  }

  List<Widget> _coverSlots() {
    final list = <Widget>[];
    for (var i = 0; i < entries.length; i++) {
      final e = entries[i];
      if (i > 0) list.add(SizedBox(width: spacing));
      list.add(
        SizedBox(
          width: cellWidth,
          child: StaggeredEntrance(
            key: ValueKey('${session}_${e.id}'),
            index: e.index,
            child: _ShelfCover(
              coverUrl: e.coverUrl,
              type: e.type,
              onTap: isSelecting ? () => onSelect(e.itemId) : e.onTap,
              onLongPress: () => onSelect(e.itemId),
              progress: e.progress,
              progressLabel: e.progressLabel,
              formatLabel: e.formatLabel,
              sourceLabel: e.sourceLabel,
              sourceId: e.sourceId,
              isSelecting: isSelecting,
              selected: selectedIds.contains(e.itemId),
            ),
          ),
        ),
      );
    }
    return list;
  }

  List<Widget> _captionSlots() {
    final list = <Widget>[];
    for (var i = 0; i < entries.length; i++) {
      final e = entries[i];
      if (i > 0) list.add(SizedBox(width: spacing));
      list.add(
        SizedBox(
          width: cellWidth,
          child: _ShelfCaption(
            title: e.title,
            subtitle: e.subtitle,
            onTap: isSelecting ? () => onSelect(e.itemId) : e.onTap,
          ),
        ),
      );
    }
    return list;
  }
}

/// 毛玻璃架板（顶面高光 + 底部投影，有厚度感，与整体玻璃风一致）
class _ShelfBoard extends StatelessWidget {
  final bool isDark;
  const _ShelfBoard({required this.isDark});

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 12,
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: isDark
              ? [
                  Colors.white.withValues(alpha: 0.16),
                  Colors.white.withValues(alpha: 0.10),
                  Colors.white.withValues(alpha: 0.04),
                ]
              : [
                  Colors.white.withValues(alpha: 0.92),
                  Colors.white.withValues(alpha: 0.65),
                  Colors.white.withValues(alpha: 0.40),
                ],
          stops: const [0.0, 0.55, 1.0],
        ),
        border: Border(
          top: BorderSide(
            color: isDark
                ? Colors.white.withValues(alpha: 0.25)
                : JellyTheme.primary.withValues(alpha: 0.25),
            width: 1,
          ),
        ),
        boxShadow: [
          BoxShadow(
            color: isDark
                ? Colors.black.withValues(alpha: 0.40)
                : JellyTheme.primary.withValues(alpha: 0.12),
            blurRadius: 6,
            offset: const Offset(0, 3),
          ),
        ],
      ),
    );
  }
}

/// 封面（立在架板上，点击缩放反馈）
class _ShelfCover extends StatefulWidget {
  final String coverUrl;
  final BookshelfItemType type;
  final VoidCallback onTap;
  final VoidCallback onLongPress;
  final double? progress;
  final String? progressLabel;
  final String? formatLabel;
  final String? sourceLabel;
  final String? sourceId; // 封面防盗链头用
  final bool isSelecting;
  final bool selected;

  const _ShelfCover({
    required this.coverUrl,
    required this.type,
    required this.onTap,
    required this.onLongPress,
    this.progress,
    this.progressLabel,
    this.formatLabel,
    this.sourceLabel,
    this.sourceId,
    this.isSelecting = false,
    this.selected = false,
  });

  @override
  State<_ShelfCover> createState() => _ShelfCoverState();
}

class _ShelfCoverState extends State<_ShelfCover> {
  bool _isPressed = false;

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    // 进度徽标：百分比（有下载）或文字（无下载在线阅读），共用同款样式
    Positioned badge(Widget child) => Positioned(
      right: 4,
      bottom: 4,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 2),
        decoration: BoxDecoration(
          color: (isDark ? Colors.black : JellyTheme.primary).withValues(
            alpha: 0.75,
          ),
          borderRadius: BorderRadius.circular(4),
        ),
        child: child,
      ),
    );
    return GestureDetector(
      onTapDown: (_) => setState(() => _isPressed = true),
      onTapUp: (_) => setState(() => _isPressed = false),
      onTapCancel: () => setState(() => _isPressed = false),
      onTap: widget.onTap,
      onLongPress: widget.onLongPress,
      child: AnimatedScale(
        scale: _isPressed ? 0.95 : 1.0,
        duration: const Duration(milliseconds: 150),
        curve: Curves.easeOut,
        child: AspectRatio(
          aspectRatio: 2 / 3,
          child: Stack(
            fit: StackFit.expand,
            children: [
              Container(
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(6),
                  color: isDark
                      ? Colors.white.withValues(alpha: 0.05)
                      : Colors.grey[200],
                  boxShadow: [
                    BoxShadow(
                      color: isDark
                          ? Colors.black.withValues(alpha: 0.45)
                          : JellyTheme.primary.withValues(alpha: 0.18),
                      blurRadius: 8,
                      offset: const Offset(0, 5),
                    ),
                  ],
                ),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(6),
                  child: _buildCoverImage(isDark),
                ),
              ),
              if (widget.isSelecting)
                Positioned(
                  top: 4,
                  left: 4,
                  child: JellySelectBadge(selected: widget.selected),
                ),
              if (!widget.isSelecting &&
                  (widget.formatLabel != null || widget.sourceLabel != null))
                Positioned(
                  top: 4,
                  left: 4,
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 5,
                      vertical: 2,
                    ),
                    decoration: BoxDecoration(
                      color: (isDark ? Colors.black : JellyTheme.primary)
                          .withValues(alpha: 0.75),
                      borderRadius: BorderRadius.circular(4),
                    ),
                    child: Text(
                      widget.formatLabel ?? widget.sourceLabel!,
                      style: const TextStyle(
                        fontSize: 9,
                        color: Colors.white,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                ),
              if (widget.progress != null)
                badge(
                  Text(
                    '${(widget.progress! * 100).round()}%',
                    style: const TextStyle(
                      fontSize: 9,
                      color: Colors.white,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                )
              else if (widget.progressLabel != null)
                badge(
                  Text(
                    widget.progressLabel!,
                    style: const TextStyle(
                      fontSize: 9,
                      color: Colors.white,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildCoverImage(bool isDark) {
    var url = widget.coverUrl;
    // 兼容旧数据：早期 PDF 与 TXT 共用 default_txt.png，重指到 PDF 专属默认封面
    // （default_pdf.png 由 BookDownloadService.init 预生成）。
    if (widget.formatLabel == 'PDF' && url.endsWith('default_txt.png')) {
      url = url.replaceAll('default_txt.png', 'default_pdf.png');
    }
    if (url.startsWith('http://') || url.startsWith('https://')) {
      return CachedNetworkImage(
        imageUrl: url,
        httpHeaders: coverHeaders(widget.sourceId),
        fit: BoxFit.cover,
        placeholder: (c, u) => _buildPlaceholder(isDark),
        errorWidget: (c, u, e) => _buildPlaceholder(isDark),
      );
    }
    if (url.isNotEmpty) {
      // 本地封面文件（导入的 epub/txt）
      return Image.file(
        File(url),
        fit: BoxFit.cover,
        errorBuilder: (_, __, ___) => _buildPlaceholder(isDark),
      );
    }
    return _buildPlaceholder(isDark);
  }

  Widget _buildPlaceholder(bool isDark) {
    return Center(
      child: Icon(
        widget.type == BookshelfItemType.comic
            ? Icons.palette_rounded
            : Icons.book_rounded,
        size: 28,
        color: isDark ? Colors.white24 : Colors.black26,
      ),
    );
  }
}

/// 书名/作者（架板下的标签，点击同封面）
class _ShelfCaption extends StatelessWidget {
  final String title;
  final String subtitle;
  final VoidCallback onTap;

  const _ShelfCaption({
    required this.title,
    required this.subtitle,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          // 书名（单行）
          Text(
            title,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w600,
              height: 1.3,
              color: isDark ? Colors.white : JellyTheme.textPrimaryLight,
            ),
          ),
          const SizedBox(height: 2),
          // 作者（单行；strutStyle 强制行高，保证等高）
          Text(
            subtitle,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            strutStyle: const StrutStyle(
              fontSize: 10,
              height: 1.3,
              forceStrutHeight: true,
            ),
            style: TextStyle(
              fontSize: 10,
              color: isDark ? Colors.white54 : JellyTheme.textSecondary,
            ),
          ),
        ],
      ),
    );
  }
}

/// 书架内容：按屏宽分列，每行封面立在架板上、书名/作者在架板下
Widget _buildShelfContent({
  required List<_ShelfEntry> entries,
  required ScrollController scrollController,
  required bool showBackToTop,
  required VoidCallback onBackToTop,
  required int session,
  required void Function(_ShelfEntry) onLongPress,
  bool isSelecting = false,
  Set<String>? selectedIds,
  ValueChanged<String>? onSelect,
}) {
  return Stack(
    children: [
      LayoutBuilder(
        builder: (context, constraints) {
          final cols = _adaptiveCols(constraints.maxWidth);
          const spacing = 12.0;
          final cellWidth =
              (constraints.maxWidth - 24 - (cols - 1) * spacing) / cols;
          final isDark = Theme.of(context).brightness == Brightness.dark;
          final rows = <List<_ShelfEntry>>[];
          for (var i = 0; i < entries.length; i += cols) {
            rows.add(entries.sublist(i, (i + cols).clamp(0, entries.length)));
          }
          return ListView.builder(
            controller: scrollController,
            padding: EdgeInsets.only(
              top: 8,
              left: 12,
              right: 12,
              bottom: 12 + JellyNavBar.contentBottomAvoid,
            ),
            itemCount: rows.length,
            itemBuilder: (context, r) => _BookshelfRow(
              cellWidth: cellWidth,
              spacing: spacing,
              isDark: isDark,
              entries: rows[r],
              session: session,
              onLongPress: onLongPress,
              isSelecting: isSelecting,
              selectedIds: selectedIds ?? const {},
              onSelect: onSelect ?? (_) {},
            ),
          );
        },
      ),
      _buildBackToTop(showBackToTop, onBackToTop),
    ],
  );
}

/// 长按书架条目：移出当前书架 / 移到其他书架
void _showShelfItemMenu(BuildContext context, String shelfId, _ShelfEntry e) {
  final isDark = Theme.of(context).brightness == Brightness.dark;
  showModalBottomSheet(
    context: context,
    backgroundColor: Colors.transparent,
    builder: (ctx) => Container(
      decoration: BoxDecoration(
        color: isDark ? const Color(0xFF252542) : Colors.white,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
      ),
      child: SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 16, 20, 4),
              child: Text(
                e.title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w600,
                  color: isDark ? Colors.white : JellyTheme.textPrimaryLight,
                ),
              ),
            ),
            ListTile(
              leading: Icon(
                Icons.remove_circle_outline_rounded,
                color: JellyTheme.error,
              ),
              title: const Text('移出当前书架'),
              onTap: () async {
                await BookshelfService().removeFromBookshelf(
                  shelfId,
                  e.itemId,
                  e.type,
                );
                if (e.type == BookshelfItemType.book) {
                  await BookDownloadService().cleanupOrphanedImport(e.itemId);
                }
                if (ctx.mounted) Navigator.pop(ctx);
              },
            ),
            ListTile(
              leading: Icon(
                Icons.swap_horiz_rounded,
                color: JellyTheme.primary,
              ),
              title: const Text('移到其他书架'),
              onTap: () async {
                Navigator.pop(ctx);
                await showBookshelfDialog(
                  context,
                  itemId: e.itemId,
                  type: e.type,
                  title: '移到其他书架',
                  meta: e.meta,
                  singleSelect: true,
                );
              },
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    ),
  );
}

// ============================================================
// 公用组件
// ============================================================
Widget _buildEmpty(BuildContext context, String text, IconData icon) {
  return Center(
    child: Column(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        Icon(icon, size: 64, color: Colors.grey),
        const SizedBox(height: 16),
        Text(text, style: const TextStyle(color: Colors.grey)),
        const SizedBox(height: 8),
        const Text(
          '去详情页加入书架吧',
          style: TextStyle(color: Colors.grey, fontSize: 12),
        ),
      ],
    ),
  );
}

Widget _buildBackToTop(bool visible, VoidCallback onTap) {
  return ListenableBuilder(
    listenable: SettingsService(),
    builder: (context, _) {
      // 与漫画/图书搜索页一致：悬浮导航栏开启时抬升避让
      final fabOffset = SettingsService().navFloating
          ? JellyNavBar.floatingTotalHeight + 8
          : 0.0;
      return Positioned(
        bottom: 16 + fabOffset,
        right: 16,
        child: AnimatedScale(
          scale: visible ? 1.0 : 0.0,
          duration: const Duration(milliseconds: 200),
          curve: Curves.easeOut,
          child: Material(
            color: JellyTheme.primary,
            shape: const CircleBorder(),
            elevation: 4,
            shadowColor: JellyTheme.primary.withValues(alpha: 0.4),
            clipBehavior: Clip.antiAlias,
            child: InkWell(
              onTap: onTap,
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
  );
}

int _adaptiveCols(double width) {
  const target = 110.0;
  const min = 3;
  const max = 6;
  final available = width - 40;
  var cols = (available / target).floor();
  if (cols < min) cols = min;
  if (cols > max) cols = max;
  return cols;
}
