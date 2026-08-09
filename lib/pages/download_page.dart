import 'dart:math' show min;
import 'dart:ui';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_staggered_grid_view/flutter_staggered_grid_view.dart';
import '../models/comic.dart';
import '../services/book_download_service.dart';
import '../services/book_reading_progress_service.dart';
import '../services/download_service.dart';
import '../services/platform_service.dart';
import '../services/reading_progress_service.dart';
import '../services/settings_service.dart';
import '../services/zlibrary_service.dart';
import '../utils/list_pagination.dart';
import '../theme/jelly_theme.dart';
import '../widgets/jelly_search_bar.dart';
import '../widgets/jelly_segmented_toggle.dart';
import '../widgets/jelly_select_badge.dart';
import '../widgets/staggered_entrance.dart';
import 'book_reader_page.dart';
import 'reader_page.dart';
import 'zlibrary_auth_page.dart';

/// 下载页卡片列数自适应：默认每行 1 个，宽度足够时增多
int _downloadAdaptiveCols(
  double width, {
  required int min,
  int max = 6,
  double target = 360,
}) {
  final available = width - 24; // 每张卡片左右各 12 margin
  var cols = (available / target).floor();
  if (cols < min) cols = min;
  if (cols > max) cols = max;
  return cols;
}

/// 下载管理页（"下载"tab）：
/// 按漫画归组，主卡片显示共多少话/阅读进度 + 开始/继续阅读；
/// 支持全部开始/继续/暂停/重试/取消、左滑删除整本、展开后单章操作（按状态条件显示）。
class DownloadPage extends StatefulWidget {
  /// 是否为当前激活的 tab（用于触发卡片入场动画）
  final bool isActive;

  /// 是否显示左上角返回按钮（从我的页面进入时为 true）
  final bool showBackButton;

  const DownloadPage({
    super.key,
    this.isActive = false,
    this.showBackButton = false,
  });

  @override
  State<DownloadPage> createState() => _DownloadPageState();
}

class _DownloadPageState extends State<DownloadPage>
    with TickerProviderStateMixin {
  final ScrollController _scrollController = ScrollController();
  final ScrollController _bookScrollController = ScrollController();
  final TextEditingController _searchController = TextEditingController();
  String _searchQuery = '';
  bool _showBackToTop = false;
  int _session = 0; // 首次切到下载 tab 时 +1，触发卡片瀑布入场动画
  bool _hasShownEntrance = false; // 是否已播过首次入场动画
  int _comicDisplayCount = ListPagination.pageSize; // 漫画 tab 滚动懒加载条数
  int _bookDisplayCount = ListPagination.pageSize; // 图书 tab 滚动懒加载条数
  int _comicTotal = 0; // 漫画 tab 过滤后总数（build 赋值，_onScroll 读）
  int _bookTotal = 0; // 图书 tab 过滤后总数

  // 多选模式
  bool _isSelecting = false;
  final Set<String> _selectedIds = {};

  late final TabController _tabController; // 0=漫画，1=图书
  String? _popupPathWord; // 当前查看章节的漫画（null=弹窗关闭）
  late final AnimationController _popupAnim;
  final ScrollController _chapterScrollController = ScrollController(
    keepScrollOffset: false,
  ); // 章节弹窗列表（每次打开从顶部开始）
  bool _showChapterBackToTop = false; // 章节弹窗是否显示返回顶部

  ScrollController get _activeScrollController =>
      _tabController.index == 0 ? _scrollController : _bookScrollController;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 2, vsync: this);
    _tabController.addListener(_onTabChanged);
    DownloadService().addListener(_onChanged);
    BookDownloadService().addListener(_onChanged);
    ReadingProgressService().addListener(_onChanged);
    _scrollController.addListener(_onScroll);
    _bookScrollController.addListener(_onScroll);
    _chapterScrollController.addListener(_onChapterScroll);
    _popupAnim = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 300),
    );
  }

  @override
  void didUpdateWidget(covariant DownloadPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    // 仅首次切到下载 tab 时重播入场动画，之后切回不再触发（避免闪烁）
    if (widget.isActive && !oldWidget.isActive && !_hasShownEntrance) {
      _hasShownEntrance = true;
      setState(() => _session++);
    }
  }

  /// 切换漫画/图书 tab：重算返回顶部按钮显隐
  void _onTabChanged() {
    final c = _activeScrollController;
    if (c.hasClients) {
      _showBackToTop = c.position.pixels > 300;
    } else {
      _showBackToTop = false;
    }
    // 切换 tab 时退出多选，避免不同类型 id 混乱
    if (_isSelecting) {
      _isSelecting = false;
      _selectedIds.clear();
    }
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    DownloadService().removeListener(_onChanged);
    BookDownloadService().removeListener(_onChanged);
    ReadingProgressService().removeListener(_onChanged);
    _tabController.removeListener(_onTabChanged);
    _tabController.dispose();
    _scrollController.removeListener(_onScroll);
    _scrollController.dispose();
    _bookScrollController.removeListener(_onScroll);
    _bookScrollController.dispose();
    _chapterScrollController.removeListener(_onChapterScroll);
    _chapterScrollController.dispose();
    _searchController.dispose();
    _popupAnim.dispose();
    super.dispose();
  }

  void _onChanged() {
    if (mounted) setState(() {});
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
              ? _buildGroups().map((g) => g.pathWord)
              : BookDownloadService().tasks.values
                    .where((t) => !t.isLocalImport)
                    .map((t) => t.bookId),
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
        title: const Text('删除下载'),
        content: Text('确定删除选中的 $count 项下载？本地文件将被删除。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    if (isComic) {
      await DownloadService().deleteComics(_selectedIds);
      for (final pw in _selectedIds) {
        await ReadingProgressService().clearComic(pw);
      }
    } else {
      await BookDownloadService().deleteBooks(_selectedIds);
    }
    if (mounted) _exitSelection();
  }

  Widget _buildSelectionBar(bool isDark) {
    return SafeArea(
      top: false,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        decoration: BoxDecoration(
          color: isDark ? JellyTheme.cardDark : JellyTheme.cardLight,
          border: Border(
            top: BorderSide(color: Colors.black.withValues(alpha: 0.08)),
          ),
        ),
        child: Row(
          children: [
            Expanded(
              child: Text(
                '已选 ${_selectedIds.length} 项',
                style: TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                  color: isDark ? Colors.white : JellyTheme.textPrimaryLight,
                ),
              ),
            ),
            TextButton(onPressed: _selectAll, child: const Text('全选')),
            const SizedBox(width: 4),
            FilledButton.icon(
              onPressed: _selectedIds.isEmpty ? null : _removeSelected,
              icon: const Icon(Icons.delete_outline_rounded, size: 18),
              label: const Text('删除'),
            ),
            const SizedBox(width: 4),
            IconButton(
              onPressed: _exitSelection,
              icon: const Icon(Icons.close_rounded),
              tooltip: '退出多选',
            ),
          ],
        ),
      ),
    );
  }

  void _onScroll() {
    final c = _activeScrollController;
    if (!c.hasClients) return;
    final isComic = _tabController.index == 0;
    final total = isComic ? _comicTotal : _bookTotal;
    final display = isComic ? _comicDisplayCount : _bookDisplayCount;
    if (ListPagination.shouldLoadMore(c) && display < total) {
      setState(() {
        if (isComic) {
          _comicDisplayCount = min(
            _comicDisplayCount + ListPagination.pageSize,
            total,
          );
        } else {
          _bookDisplayCount = min(
            _bookDisplayCount + ListPagination.pageSize,
            total,
          );
        }
      });
      return;
    }
    final show = c.position.pixels > 300;
    if (show != _showBackToTop) setState(() => _showBackToTop = show);
  }

  /// 返回顶部
  void _scrollToTop() {
    final c = _activeScrollController;
    if (c.hasClients) {
      c.animateTo(
        0,
        duration: const Duration(milliseconds: 400),
        curve: Curves.easeOutCubic,
      );
    }
  }

  /// 章节弹窗滚动监听：控制返回顶部按钮显隐
  void _onChapterScroll() {
    if (!_chapterScrollController.hasClients) return;
    final show = _chapterScrollController.position.pixels > 300;
    if (show != _showChapterBackToTop) {
      setState(() => _showChapterBackToTop = show);
    }
  }

  /// 章节弹窗返回顶部
  void _scrollChapterToTop() {
    if (_chapterScrollController.hasClients) {
      _chapterScrollController.animateTo(
        0,
        duration: const Duration(milliseconds: 400),
        curve: Curves.easeOutCubic,
      );
    }
  }

  /// 打开章节列表弹窗（高斯模糊蒙版，参考收藏页搜索弹窗）
  void _openChapterPopup(_ComicGroup g) {
    setState(() {
      _popupPathWord = g.pathWord;
      _showChapterBackToTop = false; // 新开弹窗重置返回顶部按钮
    });
    _popupAnim.forward(from: 0.0);
  }

  /// 关闭章节列表弹窗
  void _closeChapterPopup() {
    _popupAnim.reverse().then((_) {
      if (mounted) setState(() => _popupPathWord = null);
    });
  }

  /// 按漫画归组：进行中优先，其次按最近完成时间倒序
  List<_ComicGroup> _buildGroups() {
    final svc = DownloadService();
    final byComic = <String, List<DownloadTask>>{};
    for (final t in svc.tasks.values) {
      byComic.putIfAbsent(t.comicPathWord, () => []).add(t);
    }
    final groups = byComic.entries.map((e) {
      final tasks = e.value;
      final completedCount = tasks
          .where((t) => t.status == DownloadStatus.completed)
          .length;
      // 按章节顺序排序（标题章节号优先，回退 chapterOrder），便于阅读顺序展示
      final sorted = List<DownloadTask>.from(tasks)
        ..sort(
          (a, b) => chapterDisplaySortKey(
            a.chapterTitle,
            a.chapterOrder,
          ).compareTo(chapterDisplaySortKey(b.chapterTitle, b.chapterOrder)),
        );
      final hasActive = tasks.any((t) => t.status != DownloadStatus.completed);
      int? latestAt;
      for (final t in tasks) {
        if (t.downloadedAt != null &&
            (latestAt == null || t.downloadedAt! > latestAt)) {
          latestAt = t.downloadedAt;
        }
      }
      return _ComicGroup(
        pathWord: e.key,
        title: tasks.first.comicTitle,
        cover: tasks.first.comicCover,
        tasks: sorted,
        completedCount: completedCount,
        hasActive: hasActive,
        latestAt: latestAt,
      );
    }).toList();
    // 稳定排序：按 pathWord 字母序。不按状态/时间重排，避免章节完成时子项位移
    // 触发 SliverMasonryGrid 0.7.0 的 RangeError（同图书网格）。
    groups.sort((a, b) => a.pathWord.compareTo(b.pathWord));
    // 搜索过滤（按漫画标题，忽略大小写）
    final q = _searchQuery.toLowerCase();
    if (q.isNotEmpty) {
      return groups.where((g) => g.title.toLowerCase().contains(q)).toList();
    }
    return groups;
  }

  String _statusText(DownloadTask t) {
    switch (t.status) {
      case DownloadStatus.queued:
        return '排队中';
      case DownloadStatus.downloading:
        return '下载中 ${t.downloadedImages}/${t.totalImages}';
      case DownloadStatus.completed:
        if (t.missingImages > 0) {
          return '已下载 ${t.downloadedImages} 张，缺 ${t.missingImages} 张';
        }
        return '已下载 ${t.totalImages} 张';
      case DownloadStatus.failed:
        return '失败';
      case DownloadStatus.paused:
        return '已暂停';
    }
  }

  Color _statusColor(DownloadTask t) {
    switch (t.status) {
      case DownloadStatus.queued:
        return JellyTheme.textSecondary;
      case DownloadStatus.downloading:
        return JellyTheme.primary;
      case DownloadStatus.completed:
        return JellyTheme.success;
      case DownloadStatus.failed:
        return JellyTheme.error;
      case DownloadStatus.paused:
        return Colors.orange;
    }
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final titleColor = isDark ? Colors.white : JellyTheme.textPrimaryLight;
    final groups = _buildGroups(); // 漫画归组（章节弹窗复用）
    final pageBody = Stack(
      children: [
        SafeArea(
          top: !widget.showBackButton,
          child: Column(
            children: [
              _buildHeader(titleColor),
              Expanded(
                child: TabBarView(
                  controller: _tabController,
                  children: [
                    _buildComicBody(isDark, groups),
                    _buildBookBody(isDark),
                  ],
                ),
              ),
            ],
          ),
        ),
        if (_popupPathWord != null) _buildChapterPopup(groups),
      ],
    );
    final selectionBar = _isSelecting ? _buildSelectionBar(isDark) : null;
    final scaffold = widget.showBackButton
        ? Scaffold(
            appBar: AppBar(
              title: const Text('下载记录'),
              actions: [
                Padding(
                  padding: const EdgeInsets.only(right: 12),
                  child: _buildOpenDirButton(),
                ),
              ],
            ),
            floatingActionButton: _buildBackToTopButton(),
            bottomSheet: selectionBar,
            body: pageBody,
          )
        : Scaffold(
            floatingActionButton: _buildBackToTopButton(),
            bottomSheet: selectionBar,
            body: pageBody,
          );
    return PopScope(
      canPop: !_isSelecting,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop && _isSelecting) _exitSelection();
      },
      child: scaffold,
    );
  }

  /// 漫画下载内容（批量工具栏 + 漫画归组卡片）
  Widget _buildComicBody(bool isDark, List<_ComicGroup> groups) {
    final svc = DownloadService();
    _comicTotal = groups.length;
    final visibleGroups = groups.take(_comicDisplayCount).toList();

    // 批量操作可用性
    bool hasQueuedOrDownloading = false;
    bool hasPaused = false;
    bool hasFailed = false;
    bool hasNonCompleted = false;
    for (final t in svc.tasks.values) {
      switch (t.status) {
        case DownloadStatus.queued:
        case DownloadStatus.downloading:
          hasQueuedOrDownloading = true;
          hasNonCompleted = true;
          break;
        case DownloadStatus.paused:
          hasPaused = true;
          hasNonCompleted = true;
          break;
        case DownloadStatus.failed:
          hasFailed = true;
          hasNonCompleted = true;
          break;
        case DownloadStatus.completed:
          break;
      }
    }
    return CustomScrollView(
      controller: _scrollController,
      slivers: [
        SliverToBoxAdapter(
          child: ListPaginationCountBar(total: _comicTotal, unit: '本'),
        ),
        if (hasNonCompleted)
          SliverToBoxAdapter(
            child: _buildBulkToolbar(
              isDark,
              hasQueuedOrDownloading,
              hasPaused,
              hasFailed,
              hasNonCompleted,
            ),
          ),
        if (groups.isEmpty)
          SliverFillRemaining(
            hasScrollBody: false,
            child: Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    svc.tasks.isEmpty
                        ? Icons.download_for_offline_rounded
                        : Icons.search_off_rounded,
                    size: 64,
                    color: Colors.grey,
                  ),
                  const SizedBox(height: 16),
                  Text(
                    svc.tasks.isEmpty ? '暂无下载任务' : '未找到匹配的下载',
                    style: const TextStyle(color: Colors.grey),
                  ),
                ],
              ),
            ),
          )
        else
          SliverLayoutBuilder(
            builder: (context, constraints) {
              final cols = _downloadAdaptiveCols(
                constraints.crossAxisExtent,
                min: 1,
                target: 360,
                max: 6,
              );
              // 按 pathWord 集合 keyed：仅在漫画增删时重建 sliver，规避 masonry 越界。
              return SliverMasonryGrid.count(
                key: ValueKey(
                  (groups.map((g) => g.pathWord).toList()..sort()).join('|'),
                ),
                crossAxisCount: cols,
                mainAxisSpacing: 0,
                crossAxisSpacing: 0,
                childCount: visibleGroups.length,
                itemBuilder: (context, index) {
                  final g = visibleGroups[index];
                  return StaggeredEntrance(
                    key: ValueKey('${_session}_${g.pathWord}'),
                    index: index,
                    child: _buildComicCard(
                      g,
                      isDark,
                      isSelecting: _isSelecting,
                      selected: _selectedIds.contains(g.pathWord),
                      onSelect: () => _onSelect(g.pathWord),
                    ),
                  );
                },
              );
            },
          ),
      ],
    );
  }

  /// 图书下载内容（批量工具栏 + 图书任务卡片）
  Widget _buildBookBody(bool isDark) {
    final svc = BookDownloadService();
    final q = _searchQuery.toLowerCase();
    // 稳定排序：按加入顺序倒序（最新在前）。不按状态重排--任务完成时子项不位移，
    // 避免触发 SliverMasonryGrid 0.7.0 的 RangeError（包已知缺陷：子项重排/增删时
    // 渲染对象残留旧布局父数据导致越界）。
    final tasks = svc.tasks.values
        .where((t) {
          if (t.isLocalImport) return false; // 导入的书不进下载记录
          if (q.isEmpty) return true;
          return t.title.toLowerCase().contains(q) ||
              (t.author?.toLowerCase().contains(q) ?? false);
        })
        .toList()
        .reversed
        .toList();
    _bookTotal = tasks.length;
    final visibleTasks = tasks.take(_bookDisplayCount).toList();

    final hasQueuedOrDownloading = tasks.any(
      (t) =>
          t.status == BookDownloadStatus.queued ||
          t.status == BookDownloadStatus.downloading,
    );
    final hasPaused = tasks.any((t) => t.status == BookDownloadStatus.paused);
    final hasFailed = tasks.any((t) => t.status == BookDownloadStatus.failed);
    final hasNonCompleted = tasks.any(
      (t) => t.status != BookDownloadStatus.completed,
    );

    return CustomScrollView(
      controller: _bookScrollController,
      slivers: [
        SliverToBoxAdapter(
          child: ListPaginationCountBar(total: _bookTotal, unit: '本'),
        ),
        if (hasNonCompleted)
          SliverToBoxAdapter(
            child: _buildBookBulkToolbar(
              isDark,
              hasQueuedOrDownloading,
              hasPaused,
              hasFailed,
              hasNonCompleted,
            ),
          ),
        if (tasks.isEmpty)
          SliverFillRemaining(
            hasScrollBody: false,
            child: Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    svc.tasks.isEmpty
                        ? Icons.download_for_offline_rounded
                        : Icons.search_off_rounded,
                    size: 64,
                    color: Colors.grey,
                  ),
                  const SizedBox(height: 16),
                  Text(
                    svc.tasks.isEmpty ? '暂无下载任务' : '未找到匹配的下载',
                    style: const TextStyle(color: Colors.grey),
                  ),
                ],
              ),
            ),
          )
        else
          SliverLayoutBuilder(
            builder: (context, constraints) {
              final cols = _downloadAdaptiveCols(
                constraints.crossAxisExtent,
                min: 1,
                target: 360,
                max: 6,
              );
              // 按 bookId 集合 keyed：仅在增删任务时重建 sliver（清除陈旧布局状态，
              // 规避 masonry 越界）；状态/进度变化集合不变，不重建，入场动画不反复跳动。
              return SliverMasonryGrid.count(
                key: ValueKey(
                  (tasks.map((t) => t.bookId).toList()..sort()).join('|'),
                ),
                crossAxisCount: cols,
                mainAxisSpacing: 0,
                crossAxisSpacing: 0,
                childCount: visibleTasks.length,
                itemBuilder: (context, index) {
                  final t = visibleTasks[index];
                  return StaggeredEntrance(
                    key: ValueKey('${_session}_${t.bookId}'),
                    index: index,
                    child: _buildBookCard(
                      t,
                      isDark,
                      isSelecting: _isSelecting,
                      selected: _selectedIds.contains(t.bookId),
                      onSelect: () => _onSelect(t.bookId),
                    ),
                  );
                },
              );
            },
          ),
      ],
    );
  }

  Widget _buildHeader(Color titleColor) {
    // showBackButton 模式下，标题由 AppBar 承担，其余布局保持原样
    final hasTitle = !widget.showBackButton;
    return SizedBox(
      height: hasTitle ? 105 : 60,
      child: Stack(
        children: [
          // 标题：左上角，间距小（仅底部 tab 模式）
          if (hasTitle)
            Positioned(
              top: 6,
              left: 16,
              child: Text(
                '下载',
                style: TextStyle(
                  fontSize: 22,
                  fontWeight: FontWeight.bold,
                  color: titleColor,
                ),
              ),
            ),
          // 右上角：打开下载目录（仅无 AppBar 模式；AppBar 模式由 AppBar.actions 承载）
          if (hasTitle)
            Positioned(top: 6, right: 12, child: _buildOpenDirButton()),
          // 控件组：水平居中，往下错开（层次感）
          Positioned(
            top: hasTitle ? 45 : 5,
            left: 12,
            right: 12,
            child: Row(
              children: [
                const Spacer(),
                SizedBox(
                  width: MediaQuery.of(context).size.width * 0.42,
                  child: JellySearchBar(
                    controller: _searchController,
                    hintText: _tabController.index == 0 ? '搜索漫画' : '搜索图书',
                    onChanged: (v) => setState(() {
                      _searchQuery = v;
                      _comicDisplayCount = ListPagination.pageSize;
                      _bookDisplayCount = ListPagination.pageSize;
                    }),
                    onCleared: () => setState(() {
                      _searchQuery = '';
                      _comicDisplayCount = ListPagination.pageSize;
                      _bookDisplayCount = ListPagination.pageSize;
                    }),
                  ),
                ),
                const SizedBox(width: 8),
                AnimatedBuilder(
                  animation: _tabController.animation!,
                  builder: (context, _) => JellySegmentedToggle(
                    index: _tabController.animation!.value,
                    onChanged: (i) => _tabController.animateTo(i),
                    segments: const [
                      JellySegmentData(icon: Icons.palette_rounded),
                      JellySegmentData(icon: Icons.book_rounded),
                    ],
                  ),
                ),
                const Spacer(),
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// 打开下载目录：经方法通道唤起文件管理器；失败弹窗显示路径 + 复制
  Future<void> _openDownloadDir() async {
    final dir = await SettingsService.downloadBaseDir();
    final ok = await PlatformService.openDirectory(dir.path);
    if (ok) return;
    if (!mounted) return;
    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('下载目录'),
        content: SelectableText(
          '无法直接打开文件管理器，请手动前往：\n${dir.path}',
          style: const TextStyle(fontSize: 13),
        ),
        actions: [
          TextButton(
            onPressed: () async {
              await Clipboard.setData(ClipboardData(text: dir.path));
              if (ctx.mounted) Navigator.pop(ctx);
            },
            child: const Text('复制路径'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('关闭'),
          ),
        ],
      ),
    );
  }

  /// 右上角打开目录图标按钮（assets/icons/folder.png，缺省回退 Material 图标）
  Widget _buildOpenDirButton() {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Material(
      color: isDark ? JellyTheme.cardDark : Colors.white,
      shape: const CircleBorder(),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: _openDownloadDir,
        child: SizedBox(
          width: 38,
          height: 38,
          child: Center(
            child: Image.asset(
              'assets/icons/folder.png',
              width: 22,
              height: 22,
              errorBuilder: (_, _, _) => const Icon(
                Icons.folder_open_rounded,
                size: 20,
                color: JellyTheme.primary,
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildBulkToolbar(
    bool isDark,
    bool canPause,
    bool canResume,
    bool canRetry,
    bool canCancel,
  ) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 4, 12, 8),
      child: Wrap(
        alignment: WrapAlignment.center,
        spacing: 4,
        runSpacing: 4,
        children: [
          _bulkButton(
            icon: Icons.play_arrow_rounded,
            label: '开始',
            enabled: canResume,
            onTap: () => DownloadService().restartAll(),
          ),
          _bulkButton(
            icon: Icons.forward_rounded,
            label: '继续',
            enabled: canResume,
            onTap: () => DownloadService().resumeAll(),
          ),
          _bulkButton(
            icon: Icons.pause_rounded,
            label: '暂停',
            enabled: canPause,
            onTap: () => DownloadService().pauseAll(),
          ),
          _bulkButton(
            icon: Icons.refresh_rounded,
            label: '重试',
            enabled: canRetry,
            onTap: () => DownloadService().retryAll(),
          ),
          _bulkButton(
            icon: Icons.close_rounded,
            label: '取消',
            enabled: canCancel,
            onTap: _confirmCancelAll,
          ),
        ],
      ),
    );
  }

  Widget _bulkButton({
    required IconData icon,
    required String label,
    required bool enabled,
    required VoidCallback onTap,
  }) {
    return TextButton.icon(
      onPressed: enabled ? onTap : null,
      icon: Icon(icon, size: 18),
      label: Text(label, style: const TextStyle(fontSize: 12)),
      style: TextButton.styleFrom(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
        minimumSize: const Size(0, 34),
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
      ),
    );
  }

  // -------------------- 图书下载 --------------------

  Widget _buildBookBulkToolbar(
    bool isDark,
    bool canPause,
    bool canResume,
    bool canRetry,
    bool canCancel,
  ) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 4, 12, 8),
      child: Wrap(
        alignment: WrapAlignment.center,
        spacing: 4,
        runSpacing: 4,
        children: [
          _bulkButton(
            icon: Icons.play_arrow_rounded,
            label: '开始',
            enabled: canResume,
            onTap: () => BookDownloadService().restartAll(),
          ),
          _bulkButton(
            icon: Icons.forward_rounded,
            label: '继续',
            enabled: canResume,
            onTap: () => BookDownloadService().resumeAll(),
          ),
          _bulkButton(
            icon: Icons.pause_rounded,
            label: '暂停',
            enabled: canPause,
            onTap: () => BookDownloadService().pauseAll(),
          ),
          _bulkButton(
            icon: Icons.refresh_rounded,
            label: '重试',
            enabled: canRetry,
            onTap: () => BookDownloadService().retryAll(),
          ),
          _bulkButton(
            icon: Icons.close_rounded,
            label: '取消',
            enabled: canCancel,
            onTap: () => BookDownloadService().cancelAll(),
          ),
        ],
      ),
    );
  }

  Widget _buildBookCard(
    BookDownloadTask t,
    bool isDark, {
    bool isSelecting = false,
    bool selected = false,
    VoidCallback? onSelect,
  }) {
    final titleColor = isDark ? Colors.white : JellyTheme.textPrimaryLight;
    final readPct = t.status == BookDownloadStatus.completed
        ? _bookReadPercent(t)
        : null;
    final card = Container(
      margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      decoration: BoxDecoration(
        color: isDark ? JellyTheme.cardDark : JellyTheme.cardLight,
        borderRadius: BorderRadius.circular(16),
      ),
      child: Padding(
        padding: const EdgeInsets.all(10),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            _buildCover(t.cover ?? '', isDark),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    t.title,
                    style: TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w700,
                      color: titleColor,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  if (t.author != null && t.author!.isNotEmpty) ...[
                    const SizedBox(height: 4),
                    Text(
                      t.author!,
                      style: const TextStyle(
                        fontSize: 12,
                        color: JellyTheme.textSecondary,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                  const SizedBox(height: 4),
                  Row(
                    children: [
                      if (t.extension != null && t.extension!.isNotEmpty) ...[
                        Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 5,
                            vertical: 1,
                          ),
                          decoration: BoxDecoration(
                            color: JellyTheme.primary.withValues(alpha: 0.15),
                            borderRadius: BorderRadius.circular(4),
                          ),
                          child: Text(
                            t.extension!.toUpperCase(),
                            style: const TextStyle(
                              fontSize: 9,
                              color: JellyTheme.primary,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ),
                        const SizedBox(width: 6),
                      ],
                      Flexible(
                        child: Text(
                          _bookStatusText(t),
                          style: TextStyle(
                            fontSize: 11,
                            color: _bookStatusColor(t),
                          ),
                        ),
                      ),
                    ],
                  ),
                  if (t.status == BookDownloadStatus.downloading ||
                      t.status == BookDownloadStatus.queued) ...[
                    const SizedBox(height: 6),
                    ClipRRect(
                      borderRadius: BorderRadius.circular(3),
                      child: LinearProgressIndicator(
                        value: t.status == BookDownloadStatus.queued
                            ? null
                            : t.progress,
                        minHeight: 4,
                        backgroundColor: (isDark ? Colors.white : Colors.black)
                            .withValues(alpha: 0.1),
                        color: JellyTheme.primary,
                      ),
                    ),
                  ],
                  if (readPct != null) ...[
                    const SizedBox(height: 6),
                    ClipRRect(
                      borderRadius: BorderRadius.circular(3),
                      child: LinearProgressIndicator(
                        value: readPct,
                        minHeight: 4,
                        backgroundColor: (isDark ? Colors.white : Colors.black)
                            .withValues(alpha: 0.1),
                        color: JellyTheme.primary,
                      ),
                    ),
                  ],
                  if (t.status == BookDownloadStatus.failed &&
                      t.error != null) ...[
                    const SizedBox(height: 4),
                    Text(
                      '失败：${t.error}',
                      style: const TextStyle(
                        fontSize: 10,
                        color: JellyTheme.error,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                ],
              ),
            ),
            ..._buildBookActions(t),
          ],
        ),
      ),
    );

    if (isSelecting) {
      return GestureDetector(
        onTap: onSelect,
        onLongPress: onSelect,
        child: Stack(
          children: [
            IgnorePointer(child: card),
            Positioned(
              top: 8,
              right: 8,
              child: JellySelectBadge(selected: selected),
            ),
          ],
        ),
      );
    }
    // 已完成可左滑删除
    if (t.status == BookDownloadStatus.completed) {
      return Dismissible(
        key: ValueKey('book-${t.bookId}'),
        direction: DismissDirection.endToStart,
        background: Container(
          alignment: Alignment.centerRight,
          padding: const EdgeInsets.only(right: 20),
          margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
          decoration: BoxDecoration(
            color: JellyTheme.error,
            borderRadius: BorderRadius.circular(16),
          ),
          child: const Icon(Icons.delete_outline_rounded, color: Colors.white),
        ),
        confirmDismiss: (_) async {
          final ok = await showDialog<bool>(
            context: context,
            builder: (ctx) => AlertDialog(
              title: const Text('删除图书'),
              content: Text('确定删除《${t.title}》的下载文件？'),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(ctx, false),
                  child: const Text('取消'),
                ),
                TextButton(
                  onPressed: () => Navigator.pop(ctx, true),
                  child: const Text('删除'),
                ),
              ],
            ),
          );
          return ok == true;
        },
        onDismissed: (_) => BookDownloadService().deleteTask(t.bookId),
        child: GestureDetector(
          onTap: () => BookReaderPage.open(context, t),
          onLongPress: onSelect,
          child: card,
        ),
      );
    }
    return GestureDetector(onLongPress: onSelect, child: card);
  }

  List<Widget> _buildBookActions(BookDownloadTask t) {
    const density = VisualDensity.compact;
    switch (t.status) {
      case BookDownloadStatus.queued:
      case BookDownloadStatus.downloading:
        return [
          IconButton(
            icon: const Icon(Icons.pause_rounded, size: 20),
            tooltip: '暂停',
            onPressed: () => BookDownloadService().pauseTask(t.bookId),
            visualDensity: density,
          ),
          IconButton(
            icon: const Icon(Icons.close_rounded, size: 20),
            tooltip: '取消',
            onPressed: () => BookDownloadService().cancelTask(t.bookId),
            visualDensity: density,
          ),
        ];
      case BookDownloadStatus.paused:
        return [
          IconButton(
            icon: const Icon(Icons.play_arrow_rounded, size: 20),
            tooltip: '继续',
            onPressed: () => BookDownloadService().resumeTask(t.bookId),
            visualDensity: density,
          ),
          IconButton(
            icon: const Icon(Icons.close_rounded, size: 20),
            tooltip: '取消',
            onPressed: () => BookDownloadService().cancelTask(t.bookId),
            visualDensity: density,
          ),
        ];
      case BookDownloadStatus.failed:
        return [
          IconButton(
            icon: const Icon(Icons.refresh_rounded, size: 20),
            tooltip: '重试',
            onPressed: () => _retryBook(t),
            visualDensity: density,
          ),
          IconButton(
            icon: const Icon(Icons.close_rounded, size: 20),
            tooltip: '取消',
            onPressed: () => BookDownloadService().cancelTask(t.bookId),
            visualDensity: density,
          ),
        ];
      case BookDownloadStatus.completed:
        return [
          IconButton(
            icon: const Icon(Icons.menu_book_rounded, size: 20),
            tooltip: '阅读',
            onPressed: () => BookReaderPage.open(context, t),
            visualDensity: density,
          ),
        ];
    }
  }

  String _bookStatusText(BookDownloadTask t) {
    switch (t.status) {
      case BookDownloadStatus.queued:
        return '排队中';
      case BookDownloadStatus.downloading:
        return '下载中 ${(t.progress * 100).toInt()}%';
      case BookDownloadStatus.completed:
        final p = BookReadingProgressService().getProgress(t.bookId);
        if (p == null) return '未读';
        if (p.pageTotal <= 0) return '已读';
        final pct = ((p.pageIndex + 1) / p.pageTotal * 100)
            .clamp(0, 100)
            .toInt();
        return '已读 $pct%';
      case BookDownloadStatus.failed:
        return '下载失败';
      case BookDownloadStatus.paused:
        return '已暂停';
    }
  }

  Color _bookStatusColor(BookDownloadTask t) {
    switch (t.status) {
      case BookDownloadStatus.completed:
        final p = BookReadingProgressService().getProgress(t.bookId);
        if (p == null || p.pageTotal <= 0) return JellyTheme.textSecondary;
        return JellyTheme.primary;
      case BookDownloadStatus.failed:
        return JellyTheme.error;
      case BookDownloadStatus.downloading:
        return JellyTheme.primary;
      case BookDownloadStatus.queued:
      case BookDownloadStatus.paused:
        return JellyTheme.textSecondary;
    }
  }

  /// 已下载完成图书的阅读百分比（0~1，与阅读器 HUD 同为页维度）；
  /// 无进度记录或旧数据无页总数返回 null。
  double? _bookReadPercent(BookDownloadTask t) {
    final p = BookReadingProgressService().getProgress(t.bookId);
    if (p == null || p.pageTotal <= 0) return null;
    return ((p.pageIndex + 1) / p.pageTotal).clamp(0.0, 1.0);
  }

  Widget _buildCover(String cover, bool isDark) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(8),
      child: CachedNetworkImage(
        imageUrl: cover,
        width: 44,
        height: 60,
        fit: BoxFit.cover,
        placeholder: (c, u) => Container(
          color: isDark ? JellyTheme.cardDark : Colors.grey[200],
          width: 44,
          height: 60,
        ),
        errorWidget: (c, u, e) => Container(
          color: isDark ? JellyTheme.cardDark : Colors.grey[200],
          width: 44,
          height: 60,
          child: const Icon(Icons.broken_image, size: 20, color: Colors.grey),
        ),
      ),
    );
  }

  Widget _buildComicCard(
    _ComicGroup g,
    bool isDark, {
    bool isSelecting = false,
    bool selected = false,
    VoidCallback? onSelect,
  }) {
    final progress = ReadingProgressService().getProgress(g.pathWord);
    final completedIds = g.tasks
        .where((t) => t.status == DownloadStatus.completed)
        .map((t) => t.chapterId)
        .toSet();
    final seenCount = progress == null
        ? 0
        : progress.seenChapterIds.intersection(completedIds).length;
    final hasProgress = progress != null;
    final activeCount = g.tasks.length - g.completedCount;
    final titleColor = isDark ? Colors.white : JellyTheme.textPrimaryLight;

    final card = Container(
      margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      decoration: BoxDecoration(
        color: isDark ? JellyTheme.cardDark : JellyTheme.cardLight,
        borderRadius: BorderRadius.circular(16),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // 头部：封面 + 信息 + 查看章节按钮（点击弹出章节列表）
          InkWell(
            onTap: () => _openChapterPopup(g),
            borderRadius: const BorderRadius.vertical(top: Radius.circular(16)),
            child: Padding(
              padding: const EdgeInsets.all(10),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _buildCover(g.cover, isDark),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          g.title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 14,
                            fontWeight: FontWeight.w700,
                            color: titleColor,
                          ),
                        ),
                        const SizedBox(height: 4),
                        if (g.completedCount > 0) ...[
                          Text(
                            '共 ${g.completedCount} 话',
                            style: const TextStyle(
                              fontSize: 12,
                              color: JellyTheme.textSecondary,
                            ),
                          ),
                          const SizedBox(height: 6),
                          ClipRRect(
                            borderRadius: BorderRadius.circular(3),
                            child: LinearProgressIndicator(
                              value: seenCount / g.completedCount,
                              minHeight: 4,
                              backgroundColor:
                                  (isDark ? Colors.white : Colors.black)
                                      .withValues(alpha: 0.1),
                              color: JellyTheme.primary,
                            ),
                          ),
                          const SizedBox(height: 4),
                          Text(
                            hasProgress
                                ? '已读 $seenCount / ${g.completedCount} 话'
                                : '未读',
                            style: TextStyle(
                              fontSize: 11,
                              color: hasProgress
                                  ? JellyTheme.primary
                                  : JellyTheme.textSecondary,
                            ),
                          ),
                        ] else
                          const Text(
                            '暂无已完成章节',
                            style: TextStyle(
                              fontSize: 12,
                              color: JellyTheme.textSecondary,
                            ),
                          ),
                      ],
                    ),
                  ),
                  IconButton(
                    icon: const Icon(
                      Icons.format_list_numbered_rounded,
                      size: 22,
                    ),
                    tooltip: '查看章节',
                    onPressed: () => _openChapterPopup(g),
                    visualDensity: VisualDensity.compact,
                  ),
                ],
              ),
            ),
          ),
          // 操作行：开始/继续阅读 + 进行中数量
          if (g.completedCount > 0 || activeCount > 0)
            Padding(
              padding: const EdgeInsets.fromLTRB(10, 0, 10, 10),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  FilledButton.icon(
                    onPressed: g.completedCount == 0
                        ? null
                        : () => _readComic(g),
                    icon: Icon(
                      hasProgress
                          ? Icons.menu_book_rounded
                          : Icons.play_arrow_rounded,
                      size: 18,
                    ),
                    label: Text(hasProgress ? '继续阅读' : '开始阅读'),
                    style: FilledButton.styleFrom(
                      minimumSize: const Size(0, 38),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(10),
                      ),
                    ),
                  ),
                  if (activeCount > 0) ...[
                    const SizedBox(width: 8),
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 10,
                        vertical: 6,
                      ),
                      decoration: BoxDecoration(
                        color: JellyTheme.primary.withValues(alpha: 0.12),
                        borderRadius: BorderRadius.circular(10),
                      ),
                      child: Text(
                        '进行中 $activeCount',
                        style: const TextStyle(
                          fontSize: 11,
                          color: JellyTheme.primary,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                  ],
                ],
              ),
            ),
        ],
      ),
    );

    if (isSelecting) {
      return GestureDetector(
        onTap: onSelect,
        onLongPress: onSelect,
        child: Stack(
          children: [
            IgnorePointer(child: card),
            Positioned(
              top: 8,
              right: 8,
              child: JellySelectBadge(selected: selected),
            ),
          ],
        ),
      );
    }
    // 左滑删除整本（长按进入多选）
    return GestureDetector(
      onLongPress: onSelect,
      child: Dismissible(
        key: ValueKey('comic-${g.pathWord}'),
        direction: DismissDirection.endToStart,
        background: Container(
          alignment: Alignment.centerRight,
          padding: const EdgeInsets.only(right: 20),
          margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
          decoration: BoxDecoration(
            color: JellyTheme.error,
            borderRadius: BorderRadius.circular(16),
          ),
          child: const Icon(Icons.delete_outline_rounded, color: Colors.white),
        ),
        confirmDismiss: (_) => _confirmDeleteComic(g),
        child: card,
      ),
    );
  }

  /// 章节列表弹窗：高斯模糊蒙版 + 居中缩放淡入内容（参考收藏页搜索弹窗）
  Widget _buildChapterPopup(List<_ComicGroup> groups) {
    _ComicGroup? g;
    for (final e in groups) {
      if (e.pathWord == _popupPathWord) {
        g = e;
        break;
      }
    }
    if (g == null) return const SizedBox.shrink(); // 漫画已删除
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Positioned.fill(
      child: Stack(
        children: [
          // 高斯模糊蒙版（点击关闭）
          Positioned.fill(
            child: GestureDetector(
              onTap: _closeChapterPopup,
              behavior: HitTestBehavior.opaque,
              child: FadeTransition(
                opacity: _popupAnim,
                child: BackdropFilter(
                  filter: ImageFilter.blur(sigmaX: 12, sigmaY: 12),
                  child: Container(color: Colors.black.withValues(alpha: 0.2)),
                ),
              ),
            ),
          ),
          // 居中章节列表（缩放淡入）
          Center(
            child: FadeTransition(
              opacity: _popupAnim,
              child: ScaleTransition(
                scale: Tween<double>(begin: 0.92, end: 1.0).animate(
                  CurvedAnimation(
                    parent: _popupAnim,
                    curve: Curves.easeOutBack,
                  ),
                ),
                child: _buildChapterPopupContent(g, isDark),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildChapterPopupContent(_ComicGroup g, bool isDark) {
    final titleColor = isDark ? Colors.white : JellyTheme.textPrimaryLight;
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 24),
      constraints: BoxConstraints(
        maxHeight: MediaQuery.of(context).size.height * 0.6,
      ),
      child: Material(
        color: isDark ? const Color(0xFF252542) : Colors.white,
        borderRadius: BorderRadius.circular(20),
        clipBehavior: Clip.antiAlias,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // 标题栏：漫画名 + 关闭
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 10, 8, 10),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      g.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w700,
                        color: titleColor,
                      ),
                    ),
                  ),
                  IconButton(
                    icon: const Icon(Icons.close_rounded, size: 20),
                    tooltip: '关闭',
                    onPressed: _closeChapterPopup,
                    visualDensity: VisualDensity.compact,
                  ),
                ],
              ),
            ),
            Divider(
              height: 1,
              color: (isDark ? Colors.white : Colors.black).withValues(
                alpha: 0.08,
              ),
            ),
            Flexible(
              child: Stack(
                children: [
                  ListView.builder(
                    controller: _chapterScrollController,
                    padding: EdgeInsets.fromLTRB(
                      10,
                      4,
                      10,
                      // 给右下角悬浮返回顶部按钮让位，避免遮挡末行删除按钮
                      _showChapterBackToTop ? 56 : 4,
                    ),
                    shrinkWrap: true,
                    itemCount: g.tasks.length,
                    itemBuilder: (context, index) =>
                        _buildChapterRow(g.tasks[index], isDark),
                  ),
                  // 返回顶部按钮（滚动超过阈值时浮现）
                  Positioned(
                    bottom: 8,
                    right: 8,
                    child: _buildChapterBackToTopButton(),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// 单章行：状态点 + 标题/状态 + 按状态条件显示的操作按钮
  Widget _buildChapterRow(DownloadTask t, bool isDark) {
    final svc = DownloadService();
    final progress = ReadingProgressService().getProgress(t.comicPathWord);
    final isCurrent =
        progress != null && progress.lastChapterId == t.chapterId; // 正在阅读
    final seen = progress?.seenChapterIds.contains(t.chapterId) ?? false;
    final titleColor = isDark ? Colors.white : JellyTheme.textPrimaryLight;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          Container(
            width: 8,
            height: 8,
            decoration: BoxDecoration(
              color: _statusColor(t),
              shape: BoxShape.circle,
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Row(
                  children: [
                    Flexible(
                      child: Text(
                        t.chapterTitle,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w500,
                          color: titleColor,
                        ),
                      ),
                    ),
                    if (isCurrent) ...[
                      const SizedBox(width: 6),
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 6,
                          vertical: 2,
                        ),
                        decoration: BoxDecoration(
                          color: JellyTheme.blue.withValues(alpha: 0.12),
                          borderRadius: BorderRadius.circular(5),
                        ),
                        child: const Text(
                          '正在阅读',
                          style: TextStyle(
                            fontSize: 10,
                            height: 1.2,
                            color: JellyTheme.blue,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                    ] else if (seen &&
                        t.status == DownloadStatus.completed) ...[
                      const SizedBox(width: 6),
                      const Icon(
                        Icons.check_circle,
                        size: 13,
                        color: JellyTheme.blue,
                      ),
                      if (t.missingImages > 0) ...[
                        const SizedBox(width: 4),
                        Text(
                          '缺 ${t.missingImages} 张',
                          style: const TextStyle(
                            fontSize: 10,
                            color: JellyTheme.error,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ],
                    ],
                  ],
                ),
                const SizedBox(height: 2),
                Text(
                  _statusText(t),
                  style: TextStyle(fontSize: 11, color: _statusColor(t)),
                ),
              ],
            ),
          ),
          ..._buildChapterActions(t, svc),
        ],
      ),
    );
  }

  /// 按状态条件显示操作按钮（每态恰好 2 个）
  List<Widget> _buildChapterActions(DownloadTask t, DownloadService svc) {
    const density = VisualDensity.compact;
    switch (t.status) {
      case DownloadStatus.queued:
      case DownloadStatus.downloading:
        return [
          IconButton(
            icon: const Icon(Icons.pause_rounded, size: 20),
            tooltip: '暂停',
            onPressed: () => svc.pauseTask(t.key),
            visualDensity: density,
          ),
          IconButton(
            icon: const Icon(Icons.close_rounded, size: 20),
            tooltip: '取消',
            onPressed: () => svc.cancelTask(t.key),
            visualDensity: density,
          ),
        ];
      case DownloadStatus.paused:
        return [
          IconButton(
            icon: const Icon(Icons.play_arrow_rounded, size: 20),
            tooltip: '继续',
            onPressed: () => svc.resumeTask(t.key),
            visualDensity: density,
          ),
          IconButton(
            icon: const Icon(Icons.close_rounded, size: 20),
            tooltip: '取消',
            onPressed: () => svc.cancelTask(t.key),
            visualDensity: density,
          ),
        ];
      case DownloadStatus.failed:
        return [
          IconButton(
            icon: const Icon(Icons.refresh_rounded, size: 20),
            tooltip: '重试',
            onPressed: () => svc.retryTask(t.key),
            visualDensity: density,
          ),
          IconButton(
            icon: const Icon(Icons.close_rounded, size: 20),
            tooltip: '取消',
            onPressed: () => svc.cancelTask(t.key),
            visualDensity: density,
          ),
        ];
      case DownloadStatus.completed:
        return [
          if (t.missingImages > 0)
            IconButton(
              icon: const Icon(Icons.download_rounded, size: 20),
              tooltip: '重下缺图',
              onPressed: () => svc.redownloadMissing(t.key),
              visualDensity: density,
            ),
          IconButton(
            icon: const Icon(Icons.menu_book_rounded, size: 20),
            tooltip: '阅读',
            onPressed: () => _readChapter(t),
            visualDensity: density,
          ),
          IconButton(
            icon: const Icon(Icons.delete_outline_rounded, size: 20),
            tooltip: '删除',
            onPressed: () => _confirmDeleteChapter(t),
            visualDensity: density,
          ),
        ];
    }
  }

  /// 打开阅读器（离线：仅本漫画已下载章节）
  void _openReader(
    String pathWord,
    String title,
    String cover,
    ComicChapter start,
    List<ComicChapter> chapters,
    int initialPage,
  ) {
    final comic = Comic(
      id: pathWord,
      title: title,
      cover: cover,
      pathWord: pathWord,
    );
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

  /// 阅读单个已下载章节
  void _readChapter(DownloadTask t) {
    final chapters = DownloadService().downloadedChapters(t.comicPathWord);
    final idx = chapters.indexWhere((c) => c.id == t.chapterId);
    if (idx < 0) return;
    _openReader(
      t.comicPathWord,
      t.comicTitle,
      t.comicCover,
      chapters[idx],
      chapters,
      0,
    );
  }

  /// 开始/继续阅读整本：无进度从首章开始；有进度从续读章节+页码继续
  void _readComic(_ComicGroup g) {
    final chapters = DownloadService().downloadedChapters(g.pathWord);
    if (chapters.isEmpty) return;
    final progress = ReadingProgressService().getProgress(g.pathWord);
    int initialPage = 0;
    ComicChapter start = chapters.first;
    if (progress != null) {
      final idx = chapters.indexWhere((c) => c.id == progress.lastChapterId);
      if (idx >= 0) {
        start = chapters[idx];
        initialPage = progress.lastPageIndex;
      }
    }
    _openReader(g.pathWord, g.title, g.cover, start, chapters, initialPage);
  }

  void _confirmDeleteChapter(DownloadTask t) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('删除章节'),
        content: Text('确定删除「${t.chapterTitle}」的下载？'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () {
              Navigator.pop(ctx);
              DownloadService().deleteTask(t.key);
            },
            child: const Text('删除'),
          ),
        ],
      ),
    );
  }

  /// 左滑删除整本：确认后由服务驱动重建（不自行移除 Dismissible）
  Future<bool> _confirmDeleteComic(_ComicGroup g) async {
    final result = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('删除整本'),
        content: Text('确定删除「${g.title}」的全部下载（${g.completedCount} 话）？阅读进度也将清除。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (result == true) {
      await DownloadService().deleteComic(g.pathWord);
      await ReadingProgressService().clearComic(g.pathWord);
    }
    return false; // 让服务 notify 后重建移除，避免与 Dismissible 动画冲突
  }

  void _confirmCancelAll() {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('全部取消'),
        content: const Text('确定取消所有进行中/排队/暂停/失败的下载任务？'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () {
              Navigator.pop(ctx);
              DownloadService().cancelAll();
            },
            child: const Text('确定'),
          ),
        ],
      ),
    );
  }

  /// 重试图书下载：关闭内置账号且未登录时先弹登录框
  Future<void> _retryBook(BookDownloadTask t) async {
    if (!ZlibraryService().isLoggedIn && !SettingsService().useBuiltinAccount) {
      final ok = await Navigator.push<bool>(
        context,
        MaterialPageRoute(builder: (_) => const ZlibraryAuthPage()),
      );
      if (ok != true) return;
    }
    BookDownloadService().retryTask(t.bookId);
  }

  /// 章节弹窗返回顶部按钮（带出现/消失动画，缩小版）
  Widget _buildChapterBackToTopButton() {
    return AnimatedScale(
      scale: _showChapterBackToTop ? 1.0 : 0.0,
      duration: const Duration(milliseconds: 200),
      curve: Curves.easeOut,
      child: IgnorePointer(
        ignoring: !_showChapterBackToTop,
        child: AnimatedOpacity(
          opacity: _showChapterBackToTop ? 1.0 : 0.0,
          duration: const Duration(milliseconds: 200),
          child: Material(
            color: JellyTheme.primary,
            shape: const CircleBorder(),
            elevation: 4,
            clipBehavior: Clip.antiAlias,
            child: InkWell(
              onTap: _scrollChapterToTop,
              child: const SizedBox(
                width: 40,
                height: 40,
                child: Icon(
                  Icons.arrow_upward_rounded,
                  color: Colors.white,
                  size: 20,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// 悬浮返回顶部按钮（带出现/消失动画，同搜索页/详情页）
  Widget _buildBackToTopButton() {
    return AnimatedScale(
      scale: _showBackToTop ? 1.0 : 0.0,
      duration: const Duration(milliseconds: 200),
      curve: Curves.easeOut,
      child: IgnorePointer(
        ignoring: !_showBackToTop,
        child: AnimatedOpacity(
          opacity: _showBackToTop ? 1.0 : 0.0,
          duration: const Duration(milliseconds: 200),
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
      ),
    );
  }
}

/// 一本漫画的下载归组
class _ComicGroup {
  final String pathWord;
  final String title;
  final String cover;
  final List<DownloadTask> tasks; // 已按 chapterOrder 排序
  final int completedCount;
  final bool hasActive; // 是否存在非已完成任务
  final int? latestAt; // 最近完成时间戳，用于排序

  const _ComicGroup({
    required this.pathWord,
    required this.title,
    required this.cover,
    required this.tasks,
    required this.completedCount,
    required this.hasActive,
    required this.latestAt,
  });
}
