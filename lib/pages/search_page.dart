import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_staggered_grid_view/flutter_staggered_grid_view.dart';
import '../models/comic.dart';
import '../models/search_result.dart';
import '../source/adapter.dart';
import '../source/config_manga_source.dart';
import '../source/manga_source.dart';
import '../source/models.dart';
import '../source/source_manager.dart';
import '../services/browse_history_service.dart';
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
import 'browse_history_page.dart';
import 'comic_detail_page.dart';
import 'source_repo_page.dart';

/// 日志工具
void _log(String message) {
  if (kDebugMode) {
    print('[SearchPage] $message');
  }
}

/// 单个漫画源的搜索状态快照（切源时保存/恢复，使每源保留各自上次结果）
class _SourceSearchState {
  SearchResult<Comic> result = SearchResult.empty();
  String keyword = '';
  List<FilterGroup> categoryGroups = [];
  bool categoriesLoaded = false;
  bool categoryMode = false;
  int searchSession = 0;
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
  String _resultKeyword = ''; // 产生当前 _result 的词（与共享 _keyword 区分，用于缓存配对/防错配）

  bool _showBackToTop = false; // 是否显示返回顶部按钮
  bool _historyVisible = false; // 搜索历史面板是否可见
  List<String> _history = []; // 搜索历史
  int _searchSession = 0; // 每次新搜索 +1，用于触发瀑布动画

  List<FilterGroup> _categoryGroups = []; // 缓存的分类维度（首次拉取后复用）
  bool _categoriesLoaded = false; // 分类维度是否已拉取
  bool _categoryMode = false; // 分类浏览模式（与关键词搜索互斥）

  bool _pendingSearch = false; // 搜索中途切源/换词积压，待当前搜索结束后补搜
  bool _categorySheetOpening = false; // 分类筛选弹窗防连点守卫

  // 各源独立的搜索状态缓存：切源时保存/恢复，使每个源保留自己的上次结果
  final Map<String, _SourceSearchState> _sourceStates = {};

  // 各源 chip 的 GlobalKey：切源后用 Scrollable.ensureVisible 把当前 chip 居中
  final Map<String, GlobalKey> _chipKeys = {};

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
    // 监听源变化：无源空状态下，云端更新 reload 后自动切回正常搜索界面。
    SourceManager().addListener(_onSourcesChanged);
    _loadHistory();
    // 启动恢复的选中源若靠右，首帧后滚到居中可见（复用切源逻辑）
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _ensureChipVisible(SourceManager().current);
    });
  }

  @override
  void dispose() {
    _log('页面销毁');
    ViewMode().removeListener(_onViewModeChangedExternal);
    SourceManager().removeListener(_onSourcesChanged);
    _tabController.removeListener(_onTabChanged);
    _tabController.dispose();
    _searchController.dispose();
    _gridScrollController.dispose();
    _listScrollController.dispose();
    super.dispose();
  }

  /// 保存当前源的搜索状态到缓存（切源前调用）
  void _saveCurrentState(String sourceId) {
    _sourceStates[sourceId] = _SourceSearchState()
      ..result = _result
      ..keyword = _resultKeyword
      ..categoryGroups = _categoryGroups
      ..categoriesLoaded = _categoriesLoaded
      ..categoryMode = _categoryMode
      ..searchSession = _searchSession;
  }

  /// 恢复指定源缓存状态（切源后调用）；不触碰共享的 _keyword / 搜索框。
  /// 返回是否需要对当前源自动搜索（共享词非空且缓存不匹配时为 true）。
  bool _loadState(String sourceId) {
    final s = _sourceStates[sourceId];
    if (s != null) {
      _categoryGroups = s.categoryGroups;
      _categoriesLoaded = s.categoriesLoaded;
      _searchSession = s.searchSession;
      if (_keyword.isNotEmpty) {
        // 关键词模式：仅当缓存结果就是当前共享词搜出的才命中，否则待自动搜
        _categoryMode = false;
        if (s.keyword == _keyword) {
          _result = s.result;
          _resultKeyword = s.keyword;
          return false;
        } else {
          _result = SearchResult.empty();
          _resultKeyword = '';
          return true;
        }
      } else {
        // 无共享词：恢复分类态（分类模式下保留结果，否则空）
        _categoryMode = s.categoryMode;
        _result = s.categoryMode ? s.result : SearchResult.empty();
        _resultKeyword = '';
        return false;
      }
    } else {
      _result = SearchResult.empty();
      _categoryGroups = [];
      _categoriesLoaded = false;
      _categoryMode = false;
      _searchSession = 0;
      _resultKeyword = '';
      return _keyword.isNotEmpty;
    }
  }

  /// 切换当前源（chip/URL/滑动复用）：保存旧源、加载新源、按需自动搜索。
  /// 搜索框（_keyword）全局共享，切源不变。URL 兜底传 autoSearch:false 仅切源不搜。
  void _switchSource(MangaSource src, {bool autoSearch = true}) {
    FocusScope.of(context).unfocus(); // 切源/滑动属"其他情况"，主动失焦收起历史与键盘
    if (src.id == SourceManager().current.id) return; // 同源不处理
    _saveCurrentState(SourceManager().current.id); // 保存当前源状态
    SourceManager().setCurrent(src);
    final needSearch = _loadState(src.id); // 恢复该源缓存，不触碰共享搜索框
    final willSearch = needSearch && autoSearch;
    if (mounted) setState(() => _isSearching = willSearch);
    // 切源后仅将当前源 chip 居中可见（不强制回顶，保留结果列表滚动位置）
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _ensureChipVisible(src);
    });
    if (willSearch) {
      if (_isLoading) {
        _pendingSearch = true; // 当前有搜索在进行，结束后补搜
      } else {
        _doSearch();
      }
    }
  }

  /// 切源后将对应 chip 滚动到可视区中部（源较多时防当前 chip 跑出屏幕）
  void _ensureChipVisible(MangaSource src) {
    final ctx = _chipKeys[src.id]?.currentContext;
    if (ctx == null) return;
    Scrollable.ensureVisible(
      ctx,
      alignment: 0.5,
      duration: const Duration(milliseconds: 250),
      curve: Curves.easeOut,
    );
  }

  /// 当前源是否仍需按共享词搜索；用于 _pendingSearch 补搜前判断（避免重复/空词）
  void _maybeSearchCurrent() {
    if (_isLoading) return;
    final id = SourceManager().current.id;
    final cached = _sourceStates[id];
    if (_keyword.trim().isNotEmpty &&
        (cached == null || cached.keyword != _keyword)) {
      _doSearch();
    }
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
    // URL 兜底：粘贴漫画详情页 URL -> 识别站点 -> 进详情（不作为关键词保存到源状态）
    if (keyword.startsWith('http://') || keyword.startsWith('https://')) {
      _searchController.text = keyword;
      _openByUrl(keyword);
      return;
    }
    _keyword = keyword;
    _categoryMode = false; // 关键词搜索退出分类模式
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

    // loadMore 仅在无并发搜索时追加；新搜索遇忙则推迟（切源/换词中途）
    if (_isLoading) {
      if (!loadMore) _pendingSearch = true;
      _log('正在加载中，${loadMore ? "跳过 loadMore" : "推迟为新搜索"}');
      return;
    }
    if (!loadMore && _keyword.trim().isEmpty) {
      _log('关键词为空，跳过');
      return;
    }

    final srcId = SourceManager().current.id;
    // 捕获本次搜索词：loadMore 用产生当前结果的词，新搜索用共享词；防止中途变化导致缓存错配
    final searchKw = loadMore ? _resultKeyword : _keyword;

    setState(() {
      _isLoading = true;
      if (!loadMore) _isSearching = true;
    });

    try {
      final page = loadMore ? _result.currentPage : 0;
      final mangasPage = await SourceManager().current.search(
        searchKw,
        page: page,
      );
      final newResult = mangasPageToSearchResult(
        mangasPage,
        currentPage: page + 1,
      );
      _log('API返回: ${newResult.items.length} 条, 总数: ${newResult.total}');
      final stillCurrent = SourceManager().current.id == srcId;

      if (loadMore) {
        final combined = SearchResult(
          items: [..._result.items, ...newResult.items],
          total: newResult.total,
          currentPage: newResult.currentPage,
          totalPages: newResult.totalPages,
        );
        if (stillCurrent) {
          _result = combined;
          if (_sourceStates[srcId] != null) {
            _sourceStates[srcId]!.result = combined;
          }
          if (mounted) setState(() {});
        }
        // 切走则丢弃本次 loadMore 结果（返回该源可再 loadMore）
      } else {
        // 写入被搜源缓存（无论是否仍为当前源）
        final s = _sourceStates[srcId] ?? _SourceSearchState()
          ..categoryGroups = _categoryGroups
          ..categoriesLoaded = _categoriesLoaded
          ..searchSession = _searchSession;
        s
          ..result = newResult
          ..keyword = searchKw
          ..categoryMode = false;
        _sourceStates[srcId] = s;
        // 仅当仍为当前源时刷新显示（切走则只更新缓存，不污染新源显示）
        if (stillCurrent && mounted) {
          setState(() {
            _result = newResult;
            _resultKeyword = searchKw;
            _searchSession++; // 新搜索 -> 触发瀑布动画
          });
        }
      }
    } on UnsupportedSearchError catch (e) {
      _log('不支持搜索: $e');
      if (mounted && SourceManager().current.id == srcId) _toast(e.message);
    } catch (e) {
      _log('搜索异常: $e');
    } finally {
      _isLoading = false;
      if (mounted && SourceManager().current.id == srcId) {
        setState(() => _isSearching = false);
      }
      // 补搜：搜索中途切源/换词积压的请求
      if (_pendingSearch) {
        _pendingSearch = false;
        _maybeSearchCurrent();
      }
    }
  }

  void _loadMore() {
    if (_result.hasMore && !_isLoading) {
      if (_categoryMode) {
        _doCategorySearch(loadMore: true);
      } else {
        _doSearch(loadMore: true);
      }
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

  /// 源变化（云端更新 reload 等）-> 重建：无源空状态与正常搜索界面互切。
  void _onSourcesChanged() {
    if (!mounted) return;
    setState(() {});
  }

  // ========== 左右滑动：切源优先，末源过界切视图（参考书架） ==========

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

  /// 左滑（前进）：下一源；已是末源则切视图并回首源；列表末源到头无操作。
  /// 线性序列：网格A -> 网格B -> … -> 列表A -> 列表B
  void _swipeNext() {
    final sources = SourceManager().sources;
    final idx = sources.indexWhere((s) => s.id == SourceManager().current.id);
    if (idx >= 0 && idx < sources.length - 1) {
      _switchSource(sources[idx + 1]);
    } else if (_tabController.index == 0) {
      // 末源 + 网格 -> 切列表视图，回到首源
      _switchSource(sources.first);
      _tabController.animateTo(1);
    }
    // 列表末源 -> 无操作（线性序列末端）
  }

  /// 右滑（后退）：上一源；已是首源则切视图并回末源；网格首源到头无操作。
  void _swipePrev() {
    final sources = SourceManager().sources;
    final idx = sources.indexWhere((s) => s.id == SourceManager().current.id);
    if (idx > 0) {
      _switchSource(sources[idx - 1]);
    } else if (_tabController.index == 1) {
      // 首源 + 列表 -> 切网格视图，回到末源
      _switchSource(sources.last);
      _tabController.animateTo(0);
    }
    // 网格首源 -> 无操作（线性序列首端）
  }

  void _onComicTap(Comic comic) {
    FocusScope.of(context).unfocus(); // 进详情属"其他情况"，主动失焦收起历史与键盘
    BrowseHistoryService().recordComic(comic); // 记录浏览（去重置顶，仅搜索页入口记录）
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

  /// 漫画源切换小标签（横向滚动居中，样式同图书搜索页格式标签）
  Widget _buildSourceChips(bool isDark) {
    final sources = SourceManager().enabledSources;
    final currentId = SourceManager().current.id;
    final chips = <Widget>[];
    for (var i = 0; i < sources.length; i++) {
      if (i > 0) chips.add(const SizedBox(width: 8));
      final src = sources[i];
      final key = _chipKeys.putIfAbsent(src.id, () => GlobalKey());
      chips.add(_buildSourceChip(src, src.id == currentId, isDark, key: key));
    }
    return LayoutBuilder(
      builder: (context, constraints) => SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: ConstrainedBox(
          constraints: BoxConstraints(minWidth: constraints.maxWidth),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            mainAxisSize: MainAxisSize.max,
            children: chips,
          ),
        ),
      ),
    );
  }

  Widget _buildSourceChip(
    MangaSource src,
    bool selected,
    bool isDark, {
    required GlobalKey key,
  }) {
    final label = Text(
      src.name,
      style: TextStyle(
        fontSize: 12,
        fontWeight: FontWeight.w600,
        color: selected
            ? Colors.white
            : (isDark ? Colors.white70 : JellyTheme.textSecondary),
      ),
    );
    return GestureDetector(
      onTap: () => _switchSource(src),
      child: Container(
        key: key,
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        decoration: BoxDecoration(
          color: selected
              ? JellyTheme.primary
              : (isDark ? JellyTheme.cardDark : Colors.white),
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
        // 需要魔法的源：右上角叠魔法小图标
        child: src.needsMagic
            ? Stack(
                clipBehavior: Clip.none,
                children: [
                  label,
                  Positioned(
                    top: -6,
                    right: -8,
                    child: Image.asset(
                      'assets/icons/magic_stick.png',
                      width: 12,
                      height: 12,
                    ),
                  ),
                ],
              )
            : label,
      ),
    );
  }

  /// URL 兜底：粘贴漫画详情页 URL -> 识别站点 -> 切源 -> 进详情页
  Future<void> _openByUrl(String url) async {
    final uri = Uri.tryParse(url);
    if (uri == null || uri.host.isEmpty) {
      _toast('URL 无效');
      return;
    }
    // 遍历已注册的配置源按 host 识别（取代硬编码 defaultSites，远端新增站点也能识别）
    MangaSource? matched;
    for (final s in SourceManager().sources) {
      if (s is! ConfigMangaSource) continue;
      final su = Uri.tryParse(s.site.url);
      if (su != null && su.host == uri.host) {
        matched = s;
        break;
      }
    }
    if (matched == null) {
      _toast('未识别到对应站点，请检查 URL');
      return;
    }
    _switchSource(matched, autoSearch: false);
    final comic = cmangaToComic(
      CManga(id: url, sourceId: matched.id, title: '加载中…'),
    );
    if (!mounted) return;
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => ComicDetailPage(
          comic: comic,
          heroTag: comicCoverHeroTag('search', comic),
        ),
      ),
    );
  }

  void _toast(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text(msg),
          duration: const Duration(seconds: 2),
          behavior: SnackBarBehavior.floating,
        ),
      );
  }

  /// 分类筛选按钮（视图切换右边；不支持分类的源置灰）
  Widget _buildCategoryButton(bool isDark) {
    final source = SourceManager().current;
    final enabled = source.supportsCategories;
    final active = _categoryMode;
    return GestureDetector(
      onTap: enabled
          ? () => _openCategorySheet(isDark)
          : () => _toast('该源暂不支持分类筛选'),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
        decoration: BoxDecoration(
          color: active
              ? JellyTheme.primary
              : (isDark ? JellyTheme.cardDark : Colors.white),
          borderRadius: BorderRadius.circular(10),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.05),
              blurRadius: 6,
              offset: const Offset(0, 2),
            ),
          ],
        ),
        child: Icon(
          Icons.tune_rounded,
          size: 20,
          color: enabled
              ? (active
                    ? Colors.white
                    : (isDark ? Colors.white70 : JellyTheme.textSecondary))
              : (isDark ? Colors.white24 : Colors.black26),
        ),
      ),
    );
  }

  /// 浏览历史按钮（进入浏览记录页，仅漫画）
  Widget _buildBrowseHistoryButton(bool isDark) {
    return Material(
      color: JellyTheme.primary,
      shape: const CircleBorder(),
      elevation: 4,
      shadowColor: JellyTheme.primary.withValues(alpha: 0.4),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: () => Navigator.push(
          context,
          MaterialPageRoute(
            builder: (_) => const BrowseHistoryPage(showTabs: false),
          ),
        ),
        child: const SizedBox(
          width: 36,
          height: 36,
          child: Icon(Icons.history_rounded, color: Colors.white, size: 20),
        ),
      ),
    );
  }

  /// 打开分类筛选弹窗（多维度单选，多组叠加 AND，底部重置/确定）
  Future<void> _openCategorySheet(bool isDark) async {
    if (_categorySheetOpening) return; // 防连点：拉取/弹窗期间禁用
    _categorySheetOpening = true;
    FocusScope.of(context).unfocus(); // 分类按钮属"其他情况"，主动失焦收起历史与键盘
    try {
      final source = SourceManager().current;
      if (!source.supportsCategories) {
        _toast('该源暂不支持分类筛选');
        return;
      }
      // 首次拉取分类维度（缓存复用）
      if (!_categoriesLoaded) {
        setState(() => _isLoading = true);
        try {
          _categoryGroups = await source.fetchCategories();
          _categoriesLoaded = true;
        } catch (e) {
          _log('分类维度拉取失败: $e');
          _toast('分类加载失败');
          if (mounted) setState(() => _isLoading = false);
          return;
        }
        if (mounted) setState(() => _isLoading = false);
      }
      if (!mounted || _categoryGroups.isEmpty) return;

      // 弹窗内编辑副本（确认前不改动已有结果）
      var draft = _categoryGroups
          .map(
            (g) => FilterGroup(
              key: g.key,
              title: g.title,
              options: g.options,
              selected: g.selected,
            ),
          )
          .toList();

      final result = await showModalBottomSheet<List<FilterGroup>>(
        context: context,
        isScrollControlled: true,
        backgroundColor: isDark ? JellyTheme.cardDark : Colors.white,
        shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
        ),
        builder: (ctx) {
          final labelColor = isDark
              ? Colors.white
              : JellyTheme.textPrimaryLight;
          final chipColor = isDark
              ? JellyTheme.cardDark
              : const Color(0xFFF0F0F5);
          final chipTextColor = isDark
              ? Colors.white70
              : JellyTheme.textSecondary;
          return StatefulBuilder(
            builder: (ctx, setSheetState) {
              return SafeArea(
                child: ConstrainedBox(
                  constraints: BoxConstraints(
                    maxHeight: MediaQuery.of(ctx).size.height * 0.72,
                  ),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      // 标题栏
                      Padding(
                        padding: const EdgeInsets.fromLTRB(20, 14, 8, 4),
                        child: Row(
                          children: [
                            Text(
                              '分类筛选',
                              style: TextStyle(
                                fontSize: 16,
                                fontWeight: FontWeight.bold,
                                color: labelColor,
                              ),
                            ),
                            const Spacer(),
                            IconButton(
                              icon: const Icon(Icons.close_rounded),
                              onPressed: () => Navigator.pop(ctx),
                            ),
                          ],
                        ),
                      ),
                      const Divider(height: 1),
                      // 维度列表
                      Flexible(
                        child: ListView.builder(
                          shrinkWrap: true,
                          padding: const EdgeInsets.symmetric(
                            horizontal: 16,
                            vertical: 8,
                          ),
                          itemCount: draft.length,
                          itemBuilder: (_, gi) {
                            final g = draft[gi];
                            return Padding(
                              padding: const EdgeInsets.only(bottom: 12),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Padding(
                                    padding: const EdgeInsets.only(bottom: 8),
                                    child: Text(
                                      g.title,
                                      style: TextStyle(
                                        fontSize: 13,
                                        fontWeight: FontWeight.w600,
                                        color: labelColor,
                                      ),
                                    ),
                                  ),
                                  Wrap(
                                    spacing: 8,
                                    runSpacing: 8,
                                    children: g.options.map((o) {
                                      final selected =
                                          g.selected?.value == o.value ||
                                          (g.selected == null && o.isAll);
                                      return GestureDetector(
                                        onTap: () {
                                          setSheetState(() {
                                            draft[gi] = o.isAll
                                                ? g.copyWith(
                                                    clearSelected: true,
                                                  )
                                                : g.copyWith(selected: o);
                                          });
                                        },
                                        child: Container(
                                          padding: const EdgeInsets.symmetric(
                                            horizontal: 12,
                                            vertical: 6,
                                          ),
                                          decoration: BoxDecoration(
                                            color: selected
                                                ? JellyTheme.primary
                                                : chipColor,
                                            borderRadius: BorderRadius.circular(
                                              14,
                                            ),
                                          ),
                                          child: Text(
                                            o.name,
                                            style: TextStyle(
                                              fontSize: 12,
                                              fontWeight: selected
                                                  ? FontWeight.w600
                                                  : FontWeight.normal,
                                              color: selected
                                                  ? Colors.white
                                                  : chipTextColor,
                                            ),
                                          ),
                                        ),
                                      );
                                    }).toList(),
                                  ),
                                ],
                              ),
                            );
                          },
                        ),
                      ),
                      const Divider(height: 1),
                      // 底部按钮：重置 / 确定
                      Padding(
                        padding: const EdgeInsets.fromLTRB(8, 6, 12, 6),
                        child: Row(
                          children: [
                            TextButton(
                              onPressed: () {
                                setSheetState(() {
                                  for (var i = 0; i < draft.length; i++) {
                                    draft[i] = draft[i].copyWith(
                                      clearSelected: true,
                                    );
                                  }
                                });
                              },
                              child: const Text('重置'),
                            ),
                            const Spacer(),
                            FilledButton(
                              onPressed: () => Navigator.pop(ctx, draft),
                              child: const Padding(
                                padding: EdgeInsets.symmetric(
                                  horizontal: 24,
                                  vertical: 4,
                                ),
                                child: Text('确定'),
                              ),
                            ),
                          ],
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

      if (result is List<FilterGroup>) {
        _applyCategories(result);
      }
    } finally {
      _categorySheetOpening = false;
    }
  }

  /// 应用分类选择：切分类模式、清空搜索框、按分类列出
  void _applyCategories(List<FilterGroup> groups) {
    FocusScope.of(context).unfocus(); // 分类模式不聚焦搜索框，避免弹键盘
    _categoryGroups = groups;
    _categoryMode = true;
    _keyword = '';
    _resultKeyword = '';
    _searchController.clear();
    setState(() {
      _result = SearchResult.empty();
      _historyVisible = false;
    });
    _doCategorySearch();
  }

  /// 分类浏览搜索（与关键词搜索互斥；分页复用 _result）
  Future<void> _doCategorySearch({bool loadMore = false}) async {
    _log('开始分类搜索, loadMore=$loadMore');
    if (_isLoading) return;
    final srcId = SourceManager().current.id;
    setState(() {
      _isLoading = true;
      if (!loadMore) _isSearching = true;
    });
    try {
      final page = loadMore ? _result.currentPage : 0;
      final mangasPage = await SourceManager().current.getCategoryList(
        _categoryGroups,
        page: page,
      );
      final newResult = mangasPageToSearchResult(
        mangasPage,
        currentPage: page + 1,
      );
      _log('分类返回: ${newResult.items.length} 条, 总数: ${newResult.total}');
      final stillCurrent = SourceManager().current.id == srcId;

      if (loadMore) {
        final combined = SearchResult(
          items: [..._result.items, ...newResult.items],
          total: newResult.total,
          currentPage: newResult.currentPage,
          totalPages: newResult.totalPages,
        );
        if (stillCurrent) {
          _result = combined;
          if (_sourceStates[srcId] != null) {
            _sourceStates[srcId]!.result = combined;
          }
          if (mounted) setState(() {});
        }
      } else {
        final s = _sourceStates[srcId] ?? _SourceSearchState()
          ..categoryGroups = _categoryGroups
          ..categoriesLoaded = _categoriesLoaded
          ..searchSession = _searchSession;
        s
          ..result = newResult
          ..keyword = ''
          ..categoryMode = true;
        _sourceStates[srcId] = s;
        if (stillCurrent && mounted) {
          setState(() {
            _result = newResult;
            _resultKeyword = '';
            _searchSession++;
          });
        }
      }
    } catch (e) {
      _log('分类搜索异常: $e');
      if (mounted && SourceManager().current.id == srcId && !loadMore) {
        _toast('分类加载失败');
      }
    } finally {
      _isLoading = false;
      if (mounted && SourceManager().current.id == srcId) {
        setState(() => _isSearching = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    // 无可用源（未从云端更新过）：整页空状态，引导去漫画源仓库添加云端地址。
    // State 监听 SourceManager（initState 注册），云端更新 reload 后自动 rebuild 切回正常搜索界面。
    if (SourceManager().enabledSources.isEmpty) {
      return Scaffold(
        backgroundColor: widget.showBackButton ? null : Colors.transparent,
        appBar: widget.showBackButton ? AppBar(title: const Text('漫画')) : null,
        body: SafeArea(child: _buildEmptySourceState(isDark)),
      );
    }
    return Scaffold(
      backgroundColor: widget.showBackButton ? null : Colors.transparent,
      appBar: widget.showBackButton
          ? AppBar(
              title: const Text('漫画'),
              actions: [
                IconButton(
                  icon: const Icon(Icons.history_rounded),
                  tooltip: '浏览记录',
                  onPressed: () => Navigator.push(
                    context,
                    MaterialPageRoute(
                      builder: (_) => const BrowseHistoryPage(showTabs: false),
                    ),
                  ),
                ),
                const SizedBox(width: 4),
              ],
            )
          : null,
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
              height: widget.showBackButton ? 115 : 152,
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
                  // 浏览历史按钮：右上角（AppBar 模式下放 AppBar.actions）
                  if (!widget.showBackButton)
                    Positioned(
                      top: 6,
                      right: 12,
                      child: _buildBrowseHistoryButton(isDark),
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
                              if (f) {
                                if (_searchController.text.isEmpty) {
                                  _historyVisible = true;
                                }
                              } else {
                                // 失焦即收起历史（只有手动点击搜索框才获焦弹历史）
                                _historyVisible = false;
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
                            onChanged: (i) {
                              FocusScope.of(
                                context,
                              ).unfocus(); // 切视图属"其他情况"，主动失焦收起历史与键盘
                              _tabController.animateTo(i);
                            },
                            segments: const [
                              JellySegmentData(icon: Icons.grid_view_rounded),
                              JellySegmentData(icon: Icons.view_list_rounded),
                            ],
                          ),
                        ),
                        const SizedBox(width: 8),
                        _buildCategoryButton(isDark),
                        const Spacer(),
                      ],
                    ),
                  ),
                  // 源切换小标签（搜索框下方，样式同图书搜索页格式标签）
                  Positioned(
                    top: widget.showBackButton ? 52 : 96,
                    left: 12,
                    right: 12,
                    child: ListenableBuilder(
                      listenable: SourceManager(),
                      builder: (context, _) => _buildSourceChips(isDark),
                    ),
                  ),
                ],
              ),
            ),
          ),
          Expanded(
            child: Listener(
              // translucent：空态/无结果等 Center 的空白区域也能命中，
              // 否则 deferToChild 下空白处不触发 onPointerDown 导致无法滑动切源
              behavior: HitTestBehavior.translucent,
              onPointerDown: _onSwipeDown,
              onPointerUp: _onSwipeUp,
              onPointerCancel: _onSwipeCancel,
              child: _buildBody(),
            ),
          ),
        ],
      ),
    );
  }

  /// 无可用源空状态：提示去漫画源仓库添加云端地址并更新。
  Widget _buildEmptySourceState(bool isDark) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.cloud_off_rounded,
              size: 64,
              color: JellyTheme.textSecondary,
            ),
            const SizedBox(height: 16),
            Text(
              '暂无漫画源',
              style: TextStyle(
                fontSize: 17,
                fontWeight: FontWeight.bold,
                color: isDark ? Colors.white : JellyTheme.textPrimaryLight,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              '请到「漫画源仓库」填入云端地址并更新',
              style: TextStyle(fontSize: 13, color: JellyTheme.textSecondary),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 20),
            FilledButton.icon(
              onPressed: () => Navigator.push(
                context,
                MaterialPageRoute(builder: (_) => const SourceRepoPage()),
              ),
              icon: const Icon(Icons.cloud_download_rounded, size: 18),
              label: const Text('去添加漫画源'),
            ),
          ],
        ),
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
    // 搜索框聚焦且为空 -> 显示搜索历史（分类模式下不显示历史）
    if (_showHistory && !_categoryMode) return _buildHistory();

    // 搜索/筛选中 -> 显示加载（文案区分关键词/分类）
    if (_isSearching) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            CircularProgressIndicator(color: JellyTheme.primary),
            const SizedBox(height: 16),
            Text(
              _categoryMode ? '正在筛选...' : '正在搜索...',
              style: const TextStyle(color: Colors.grey),
            ),
          ],
        ),
      );
    }

    // 无结果（关键词或分类模式均适用）
    if (_result.items.isEmpty &&
        (_keyword.isNotEmpty || _categoryMode) &&
        !_isSearching) {
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
    if (_result.items.isEmpty && _keyword.isEmpty && !_categoryMode) {
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

    // 结果：网格/列表由分段开关/滑动切源过界驱动（TabBarView 自身禁横滑，
    // 左右滑动手势由外层 Listener 接管用于切源/切视图，参考书架）
    return TabBarView(
      controller: _tabController,
      physics: const NeverScrollableScrollPhysics(),
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
              return Center(
                child: Padding(
                  padding: const EdgeInsets.all(16.0),
                  child: CircularProgressIndicator(color: JellyTheme.primary),
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
              return Center(
                child: Padding(
                  padding: const EdgeInsets.all(16.0),
                  child: CircularProgressIndicator(color: JellyTheme.primary),
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
