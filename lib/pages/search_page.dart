import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_staggered_grid_view/flutter_staggered_grid_view.dart';
import '../models/comic.dart';
import '../models/search_result.dart';
import '../services/comic_api.dart';
import '../services/search_history_service.dart';
import '../services/view_mode.dart';
import '../theme/jelly_theme.dart';
import '../services/settings_service.dart';
import '../widgets/jelly_comic_card.dart';
import '../widgets/jelly_nav_bar.dart';
import '../widgets/jelly_comic_list_tile.dart';
import '../widgets/jelly_search_bar.dart';
import '../widgets/jelly_segmented_toggle.dart';
import '../widgets/staggered_entrance.dart';
import 'comic_detail_page.dart';

/// 日志工具
void _log(String message) {
  if (kDebugMode) {
    print('[SearchPage] $message');
  }
}

/// 漫画搜索页面（果冻风悬浮搜索框）
class SearchPage extends StatefulWidget {
  /// 是否为当前激活的 tab（用于触发结果瀑布入场动画）
  final bool isActive;

  /// 是否显示返回按钮（从"我的"页面入口进入时为 true）
  final bool showBackButton;

  const SearchPage({
    super.key,
    this.isActive = false,
    this.showBackButton = false,
  });

  @override
  State<SearchPage> createState() => _SearchPageState();
}

class _SearchPageState extends State<SearchPage> with TickerProviderStateMixin {
  final ComicApi _api = ComicApi();
  final TextEditingController _searchController = TextEditingController();

  // 网格/列表视图切换控制器（参考下载页：滑块与 TabBarView 由同一 animation 驱动，1:1 同步）
  late final TabController _tabController;

  // 两种视图各自独立的滚动控制器，避免切换时冲突卡死
  final ScrollController _gridScrollController = ScrollController();
  final ScrollController _listScrollController = ScrollController();

  SearchResult<Comic> _result = SearchResult.empty();
  bool _isLoading = false;
  bool _isSearching = false;
  String _keyword = '';

  bool _showBackToTop = false; // 是否显示返回顶部按钮
  bool _historyVisible = false; // 搜索历史面板是否可见
  List<String> _history = []; // 搜索历史
  int _searchSession = 0; // 每次新搜索 +1，用于触发瀑布动画

  ScrollController get _activeScrollController =>
      _tabController.index == 0 ? _gridScrollController : _listScrollController;

  bool get _showHistory => _historyVisible && _searchController.text.isEmpty;

  @override
  void initState() {
    super.initState();
    _log('页面初始化');
    _tabController = TabController(
      length: 2,
      vsync: this,
      initialIndex: ViewMode().isGrid ? 0 : 1,
    );
    _tabController.addListener(_onTabChanged);
    _gridScrollController.addListener(() => _onScroll(_gridScrollController));
    _listScrollController.addListener(() => _onScroll(_listScrollController));
    ViewMode().addListener(_onViewModeChangedExternal);
    _loadHistory();
  }

  @override
  void dispose() {
    _log('页面销毁');
    ViewMode().removeListener(_onViewModeChangedExternal);
    _tabController.removeListener(_onTabChanged);
    _tabController.dispose();
    _searchController.dispose();
    _gridScrollController.dispose();
    _listScrollController.dispose();
    super.dispose();
  }

  Future<void> _loadHistory() async {
    final h = await SearchHistoryService.load();
    _log('加载搜索历史: ${h.length} 条');
    if (mounted) setState(() => _history = h);
  }

  Future<void> _addHistory(String keyword) async {
    final h = await SearchHistoryService.add(keyword);
    _log('添加搜索历史 "$keyword" -> 共 ${h.length} 条');
    if (mounted) setState(() => _history = h);
  }

  Future<void> _removeHistory(String keyword) async {
    _log('删除搜索历史: $keyword');
    final h = await SearchHistoryService.remove(keyword);
    _log('删除后剩余 ${h.length} 条');
    if (mounted) setState(() => _history = h);
  }

  Future<void> _clearHistory() async {
    _log('清空搜索历史');
    final h = await SearchHistoryService.clear();
    if (mounted) setState(() => _history = h);
  }

  void _onScroll(ScrollController controller) {
    if (!controller.hasClients) return;
    final pixels = controller.position.pixels;
    final max = controller.position.maxScrollExtent;
    if (pixels >= max - 200 && max > 0) {
      _loadMore();
    }
    final show = pixels > 300;
    if (show != _showBackToTop) {
      setState(() => _showBackToTop = show);
    }
  }

  /// 执行一次搜索（来自提交或历史记录点击）
  void _runSearch(String keyword) {
    _log('runSearch: "$keyword"');
    FocusScope.of(context).unfocus();
    _keyword = keyword;
    _searchController.text = keyword;
    _searchController.selection = TextSelection.collapsed(
      offset: keyword.length,
    );
    setState(() {}); // 退出历史面板
    _addHistory(keyword);
    _doSearch();
  }

  Future<void> _doSearch({bool loadMore = false}) async {
    _log('开始搜索, loadMore=$loadMore, isLoading=$_isLoading, keyword=$_keyword');

    if (_isLoading) {
      _log('正在加载中，跳过');
      return;
    }
    if (!loadMore && _keyword.trim().isEmpty) {
      _log('关键词为空，跳过');
      return;
    }

    setState(() {
      _isLoading = true;
      if (!loadMore) _isSearching = true;
    });

    try {
      final page = loadMore ? _result.currentPage : 0;
      final newResult = await _api.searchComic(_keyword, page: page);
      _log('API返回: ${newResult.items.length} 条, 总数: ${newResult.total}');

      if (mounted) {
        setState(() {
          if (loadMore) {
            _result = SearchResult(
              items: [..._result.items, ...newResult.items],
              total: newResult.total,
              currentPage: newResult.currentPage,
              totalPages: newResult.totalPages,
            );
          } else {
            _result = newResult;
            _searchSession++; // 新搜索 -> 触发瀑布动画
          }
        });
      }
    } catch (e) {
      _log('搜索异常: $e');
    } finally {
      if (mounted) {
        setState(() {
          _isLoading = false;
          _isSearching = false;
        });
      }
    }
  }

  void _loadMore() {
    if (_result.hasMore && !_isLoading) {
      _doSearch(loadMore: true);
    }
  }

  /// 返回顶部
  void _scrollToTop() {
    final controller = _activeScrollController;
    if (controller.hasClients) {
      controller.animateTo(
        0,
        duration: const Duration(milliseconds: 400),
        curve: Curves.easeOutCubic,
      );
    }
  }

  /// tab 停稳后回写 ViewMode（持久化 + 供收藏页/显示设置页联动）；幂等判断防循环
  void _onTabChanged() {
    if (!_tabController.indexIsChanging) {
      final isGrid = _tabController.index == 0;
      if (ViewMode().isGrid != isGrid) ViewMode().set(isGrid);
    }
    final c = _activeScrollController;
    final show = c.hasClients && c.position.pixels > 300;
    if (show != _showBackToTop) {
      _showBackToTop = show;
      if (mounted) setState(() {});
    }
  }

  /// 外部（显示设置页等）改了 ViewMode -> 同步 tab；幂等判断防循环
  void _onViewModeChangedExternal() {
    if (!mounted) return;
    final target = ViewMode().isGrid ? 0 : 1;
    if (_tabController.index != target) {
      _tabController.animateTo(target);
    }
  }

  void _onComicTap(Comic comic) {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (context) => ComicDetailPage(
          comic: comic,
          heroTag: comicCoverHeroTag('search', comic),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Scaffold(
      appBar: widget.showBackButton ? AppBar(title: const Text('漫画')) : null,
      floatingActionButton: ListenableBuilder(
        listenable: SettingsService(),
        builder: (context, _) {
          final fabOffset = SettingsService().navFloating
              ? JellyNavBar.floatingTotalHeight + 8
              : 0.0;
          return Padding(
            padding: EdgeInsets.only(bottom: fabOffset),
            child: _buildBackToTopButton(),
          );
        },
      ),
      body: Column(
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
                        '漫画',
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
                        SizedBox(
                          width: MediaQuery.of(context).size.width * 0.4,
                          child: JellySearchBar(
                            controller: _searchController,
                            onFocusChange: (f) => setState(() {
                              if (f && _searchController.text.isEmpty) {
                                _historyVisible = true;
                              }
                            }),
                            onCleared: () =>
                                setState(() => _historyVisible = false),
                            onSubmitted: (value) => _runSearch(value),
                            onChanged: (value) => setState(() {}),
                          ),
                        ),
                        const SizedBox(width: 8),
                        AnimatedBuilder(
                          animation: _tabController.animation!,
                          builder: (context, _) => JellySegmentedToggle(
                            index: _tabController.animation!.value,
                            onChanged: (i) => _tabController.animateTo(i),
                            segments: const [
                              JellySegmentData(icon: Icons.grid_view_rounded),
                              JellySegmentData(icon: Icons.view_list_rounded),
                            ],
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
          Expanded(child: _buildBody()),
        ],
      ),
    );
  }

  /// 悬浮返回顶部按钮（带出现/消失动画）
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

  Widget _buildBody() {
    // 搜索框聚焦且为空 -> 显示搜索历史
    if (_showHistory) return _buildHistory();

    // 搜索中 -> 显示"正在搜索"（每次新搜索都先显示）
    if (_isSearching) {
      return const Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            CircularProgressIndicator(color: Color(0xFF6D73AA)),
            SizedBox(height: 16),
            Text('正在搜索...', style: TextStyle(color: Colors.grey)),
          ],
        ),
      );
    }

    // 无结果
    if (_result.items.isEmpty && _keyword.isNotEmpty && !_isSearching) {
      return const Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.search_off_rounded, size: 64, color: Colors.grey),
            SizedBox(height: 16),
            Text('没有找到相关漫画', style: TextStyle(color: Colors.grey)),
          ],
        ),
      );
    }

    // 未搜索 = 初始界面
    if (_result.items.isEmpty) {
      return const Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.palette_rounded, size: 64, color: Colors.grey),
            SizedBox(height: 16),
            Text('输入关键词开始搜索漫画', style: TextStyle(color: Colors.grey)),
          ],
        ),
      );
    }

    // 结果：网格/列表用 TabBarView 横向滑动切换（参考下载页，滑块与内容 1:1 同步）
    return TabBarView(
      controller: _tabController,
      children: [_buildGridView(), _buildListView()],
    );
  }

  /// 搜索历史面板
  Widget _buildHistory() {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final labelColor = isDark ? Colors.white : JellyTheme.textPrimaryLight;
    // 点击空白区域关闭历史面板（点历史项仍正常搜索：项的 onTap 优先）
    return GestureDetector(
      onTap: () => setState(() => _historyVisible = false),
      child: ListView(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
            child: Row(
              children: [
                Text(
                  '搜索历史',
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                    color: labelColor,
                  ),
                ),
                const Spacer(),
                if (_history.isNotEmpty)
                  TextButton(
                    onPressed: _clearHistory,
                    child: const Text('清空', style: TextStyle(fontSize: 13)),
                  ),
              ],
            ),
          ),
          if (_history.isEmpty)
            const Padding(
              padding: EdgeInsets.all(40),
              child: Center(
                child: Text('暂无搜索历史', style: TextStyle(color: Colors.grey)),
              ),
            )
          else
            ..._history.map(
              (kw) => ListTile(
                leading: const Icon(Icons.history_rounded, color: Colors.grey),
                title: Text(kw),
                trailing: IconButton(
                  icon: const Icon(
                    Icons.close_rounded,
                    color: Colors.grey,
                    size: 18,
                  ),
                  onPressed: () => _removeHistory(kw),
                ),
                onTap: () => _runSearch(kw),
              ),
            ),
        ],
      ),
    );
  }

  /// 瀑布入场 key（新搜索时变化触发动画；isGrid 为各视图固定标记，
  /// 避免 tab 动画过程中 index 翻转导致 key 变化、元素重挂闪烁）
  Key _entranceKey(int index, {required bool isGrid}) =>
      ValueKey('${isGrid}_${_searchSession}_$index');

  /// 根据可用宽度自适应列数
  int _adaptiveColumns(
    double width, {
    required int min,
    int max = 6,
    double target = 170,
  }) {
    final available = width - 40; // 左右各 20 内边距
    var cols = (available / target).floor();
    if (cols < min) cols = min;
    if (cols > max) cols = max;
    return cols;
  }

  /// 网格视图（瀑布流，列数自适应，默认 2 列）
  Widget _buildGridView() {
    return LayoutBuilder(
      builder: (context, constraints) {
        final cols = _adaptiveColumns(
          constraints.maxWidth,
          min: 2,
          target: 170,
        );
        return MasonryGridView.count(
          controller: _gridScrollController,
          padding: EdgeInsets.only(
            top: 4,
            left: 12,
            right: 12,
            bottom: 12 + JellyNavBar.contentBottomAvoid,
          ),
          crossAxisCount: cols,
          mainAxisSpacing: 12,
          crossAxisSpacing: 12,
          itemCount: _result.items.length + (_result.hasMore ? 1 : 0),
          itemBuilder: (context, index) {
            if (index == _result.items.length) {
              return const Center(
                child: Padding(
                  padding: EdgeInsets.all(16.0),
                  child: CircularProgressIndicator(color: Color(0xFF6D73AA)),
                ),
              );
            }
            final comic = _result.items[index];
            return StaggeredEntrance(
              key: _entranceKey(index, isGrid: true),
              index: index,
              child: JellyComicCard(
                comic: comic,
                heroTag: comicCoverHeroTag('search', comic),
                onTap: () => _onComicTap(comic),
              ),
            );
          },
        );
      },
    );
  }

  /// 列表视图（横向卡片，列数自适应）
  Widget _buildListView() {
    return LayoutBuilder(
      builder: (context, constraints) {
        final cols = _adaptiveColumns(
          constraints.maxWidth,
          min: 1,
          target: 360,
          max: 4,
        );
        return MasonryGridView.count(
          controller: _listScrollController,
          padding: EdgeInsets.only(
            top: 4,
            left: 12,
            right: 12,
            bottom: 12 + JellyNavBar.contentBottomAvoid,
          ),
          crossAxisCount: cols,
          mainAxisSpacing: 12,
          crossAxisSpacing: 12,
          itemCount: _result.items.length + (_result.hasMore ? 1 : 0),
          itemBuilder: (context, index) {
            if (index == _result.items.length) {
              return const Center(
                child: Padding(
                  padding: EdgeInsets.all(16.0),
                  child: CircularProgressIndicator(color: Color(0xFF6D73AA)),
                ),
              );
            }
            final comic = _result.items[index];
            return StaggeredEntrance(
              key: _entranceKey(index, isGrid: false),
              index: index,
              child: JellyComicListTile(
                comic: comic,
                heroTag: comicCoverHeroTag('search', comic),
                onTap: () => _onComicTap(comic),
              ),
            );
          },
        );
      },
    );
  }
}
