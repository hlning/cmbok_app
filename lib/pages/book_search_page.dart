import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_staggered_grid_view/flutter_staggered_grid_view.dart';
import '../models/book.dart';
import '../models/search_result.dart';
import '../services/book_download_service.dart';
import '../services/book_view_mode.dart';
import '../services/search_history_service.dart';
import '../services/zlibrary_service.dart';
import '../theme/jelly_theme.dart';
import '../services/settings_service.dart';
import '../widgets/jelly_book_card.dart';
import '../widgets/jelly_nav_bar.dart';
import '../widgets/jelly_search_bar.dart';
import '../widgets/jelly_segmented_toggle.dart';
import '../widgets/staggered_entrance.dart';
import 'book_detail_page.dart';
import 'zlibrary_auth_page.dart';

/// 日志工具
void _log(String message) {
  if (kDebugMode) {
    print('[BookSearchPage] $message');
  }
}

/// 图书搜索页面（果冻风，布局同漫画搜索 + 格式筛选 + 右上角 z-library 登录头像）
class BookSearchPage extends StatefulWidget {
  /// 是否为当前激活的 tab（用于触发结果瀑布入场动画）
  final bool isActive;

  /// 是否显示返回按钮（从"我的"页面入口进入时为 true）
  final bool showBackButton;

  const BookSearchPage({
    super.key,
    this.isActive = false,
    this.showBackButton = false,
  });

  @override
  State<BookSearchPage> createState() => _BookSearchPageState();
}

class _BookSearchPageState extends State<BookSearchPage>
    with TickerProviderStateMixin {
  final TextEditingController _searchController = TextEditingController();

  // 网格/列表视图切换控制器（参考下载页：滑块与 TabBarView 由同一 animation 驱动，1:1 同步）
  late final TabController _tabController;

  // 两种视图各自独立的滚动控制器，避免切换时冲突卡死
  final ScrollController _gridScrollController = ScrollController();
  final ScrollController _listScrollController = ScrollController();

  SearchResult<Book> _result = SearchResult.empty();
  bool _isLoading = false;
  bool _isSearching = false;
  String _keyword = '';
  String _format = ''; // '' = 全部，否则 EPUB/PDF/...

  bool _showBackToTop = false;
  bool _historyVisible = false;
  List<String> _history = [];
  int _searchSession = 0;
  String? _errorMsg; // 搜索异常信息
  /// z-library 可用性上一状态（仅状态变化才弹通知；null=尚未初始化）
  bool? _wasUnavailable;

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
      initialIndex: BookViewMode().isGrid ? 0 : 1,
    );
    _tabController.addListener(_onTabChanged);
    _gridScrollController.addListener(() => _onScroll(_gridScrollController));
    _listScrollController.addListener(() => _onScroll(_listScrollController));
    BookViewMode().addListener(_onViewModeChangedExternal);
    ZlibraryService().addListener(_onServiceChanged);
    BookDownloadService().addListener(_onServiceChanged);
    _wasUnavailable = ZlibraryService().isUnavailable;
    _loadHistory();
  }

  @override
  void dispose() {
    _log('页面销毁');
    BookViewMode().removeListener(_onViewModeChangedExternal);
    ZlibraryService().removeListener(_onServiceChanged);
    BookDownloadService().removeListener(_onServiceChanged);
    _tabController.removeListener(_onTabChanged);
    _tabController.dispose();
    _searchController.dispose();
    _gridScrollController.dispose();
    _listScrollController.dispose();
    super.dispose();
  }

  void _onServiceChanged() {
    if (!mounted) return;
    final unavailable = ZlibraryService().isUnavailable;
    final prev = _wasUnavailable;
    _wasUnavailable = unavailable;
    // 仅状态变化才弹通知（恢复/受限）
    if (prev != null && prev != unavailable) {
      _notifyAvailability(unavailable);
    }
    setState(() {});
  }

  void _notifyAvailability(bool unavailable) {
    final msg = unavailable
        ? '所有 z-library 节点不可用，图书功能暂不可用，请等待恢复'
        : 'z-library 节点已恢复可用';
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text(msg),
          duration: unavailable
              ? const Duration(seconds: 8)
              : const Duration(seconds: 4),
          behavior: SnackBarBehavior.floating,
        ),
      );
  }

  Future<void> _loadHistory() async {
    final h = await SearchHistoryService.load(key: 'book_search_history');
    _log('加载搜索历史: ${h.length} 条');
    if (mounted) setState(() => _history = h);
  }

  Future<void> _addHistory(String keyword) async {
    final h = await SearchHistoryService.add(
      keyword,
      key: 'book_search_history',
    );
    if (mounted) setState(() => _history = h);
  }

  Future<void> _removeHistory(String keyword) async {
    final h = await SearchHistoryService.remove(
      keyword,
      key: 'book_search_history',
    );
    if (mounted) setState(() => _history = h);
  }

  Future<void> _clearHistory() async {
    final h = await SearchHistoryService.clear(key: 'book_search_history');
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
  Future<void> _runSearch(String keyword) async {
    _log('runSearch: "$keyword"');
    FocusScope.of(context).unfocus();
    _keyword = keyword;
    _searchController.text = keyword;
    _searchController.selection = TextSelection.collapsed(
      offset: keyword.length,
    );
    setState(() {
      _historyVisible = false;
      _errorMsg = null;
    });
    // 未登录时默认使用内置账号搜索（不受"使用内置账号"开关限制），无需弹登录框
    _addHistory(keyword);
    _doSearch();
  }

  Future<void> _doSearch({bool loadMore = false}) async {
    _log('开始搜索, loadMore=$loadMore, isLoading=$_isLoading, keyword=$_keyword');

    if (_isLoading) return;
    if (!loadMore && _keyword.trim().isEmpty) return;

    setState(() {
      _isLoading = true;
      _errorMsg = null;
      if (!loadMore) _isSearching = true;
    });

    try {
      final page = loadMore ? _result.currentPage + 1 : 1;
      final newResult = await ZlibraryService().search(
        _keyword,
        extensions: _format.isEmpty ? null : _format,
        page: page,
      );
      _log('API返回: ${newResult.items.length} 条, 总数: ${newResult.total}');

      if (mounted) {
        setState(() {
          if (loadMore) {
            _result = SearchResult<Book>(
              items: [..._result.items, ...newResult.items],
              total: newResult.total,
              currentPage: newResult.currentPage,
              totalPages: newResult.totalPages,
            );
          } else {
            _result = newResult;
            _searchSession++;
          }
        });
      }
    } on ZlibraryException catch (e) {
      _log('搜索业务异常: ${e.code} ${e.message}');
      if (mounted) setState(() => _errorMsg = _friendlyError(e));
    } catch (e) {
      _log('搜索异常: $e');
      if (mounted) setState(() => _errorMsg = '搜索失败，请检查网络或稍后重试');
    } finally {
      if (mounted) {
        setState(() {
          _isLoading = false;
          _isSearching = false;
        });
      }
    }
  }

  String _friendlyError(ZlibraryException e) {
    switch (e.code) {
      case 'no_account':
        return '没有可用的内置账号，请登录自有账号';
      case 'no_login':
        return '登录已失效，请重新登录';
      case 'unavailable':
        return '图书功能暂不可用，请等待恢复';
      case 'rate_limited':
        return '请求过于频繁，请稍后再试';
      default:
        return e.message;
    }
  }

  void _loadMore() {
    if (_result.hasMore && !_isLoading) {
      _doSearch(loadMore: true);
    }
  }

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

  /// tab 停稳后回写 BookViewMode（持久化 + 供图书收藏页/显示设置页联动）；幂等判断防循环
  void _onTabChanged() {
    if (!_tabController.indexIsChanging) {
      final isGrid = _tabController.index == 0;
      if (BookViewMode().isGrid != isGrid) BookViewMode().set(isGrid);
    }
    final c = _activeScrollController;
    final show = c.hasClients && c.position.pixels > 300;
    if (show != _showBackToTop) {
      _showBackToTop = show;
      if (mounted) setState(() {});
    }
  }

  /// 外部（显示设置页等）改了 BookViewMode -> 同步 tab；幂等判断防循环
  void _onViewModeChangedExternal() {
    if (!mounted) return;
    final target = BookViewMode().isGrid ? 0 : 1;
    if (_tabController.index != target) {
      _tabController.animateTo(target);
    }
  }

  // -------------------- 详情 --------------------

  void _openDetail(Book book) {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => BookDetailPage(
          book: book,
          heroTag: bookCoverHeroTag('search', book),
          searchResults: _result.items,
        ),
      ),
    );
  }

  void _showTip(String msg) {
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

  // -------------------- 头像 / 登录 --------------------

  Future<void> _onAvatarTap() async {
    final z = ZlibraryService();
    if (z.isLoggedIn) {
      // 已登录：弹出账号信息 + 退出登录
      await _showLogoutDialog(z);
      return;
    }
    // 未登录：弹登录框
    final ok = await Navigator.push<bool>(
      context,
      MaterialPageRoute(builder: (_) => const ZlibraryAuthPage()),
    );
    if (ok == true && mounted) {
      _showTip('登录成功');
    }
  }

  /// 已登录账号弹窗：展示账号信息 + 今日下载配额 + 退出登录（果冻风）
  Future<void> _showLogoutDialog(ZlibraryService z) async {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final limit = z.serverDownloadsLimit ?? ZlibraryService.loggedDailyLimit;
    final used = z.loggedCountToday;
    final action = await showDialog<String>(
      context: context,
      builder: (ctx) => Dialog(
        backgroundColor: Colors.transparent,
        elevation: 0,
        child: Container(
          padding: const EdgeInsets.fromLTRB(24, 24, 24, 16),
          decoration: BoxDecoration(
            color: isDark ? JellyTheme.cardDark : Colors.white,
            borderRadius: BorderRadius.circular(24),
            boxShadow: JellyTheme.jellyShadows(
              color: JellyTheme.primary,
              blurRadius: 30,
            ),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              // 头像（与顶栏一致：主色圆底 + user.png）
              Container(
                width: 64,
                height: 64,
                decoration: const BoxDecoration(
                  color: JellyTheme.primary,
                  shape: BoxShape.circle,
                ),
                child: Center(
                  child: Image.asset(
                    'assets/icons/user.png',
                    width: 44,
                    height: 44,
                    fit: BoxFit.cover,
                    errorBuilder: (_, _, _) => const Icon(
                      Icons.person_rounded,
                      color: Colors.white,
                      size: 32,
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 12),
              Text(
                z.username.isEmpty ? z.email : z.username,
                style: TextStyle(
                  fontSize: 17,
                  fontWeight: FontWeight.w700,
                  color: isDark ? Colors.white : JellyTheme.textPrimaryLight,
                ),
              ),
              if (z.username.isNotEmpty) ...[
                const SizedBox(height: 2),
                Text(
                  z.email,
                  style: const TextStyle(
                    fontSize: 13,
                    color: JellyTheme.textSecondary,
                  ),
                ),
              ],
              const SizedBox(height: 16),
              // 今日下载配额
              Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 14,
                  vertical: 10,
                ),
                decoration: BoxDecoration(
                  color: JellyTheme.primary.withValues(
                    alpha: isDark ? 0.18 : 0.08,
                  ),
                  borderRadius: BorderRadius.circular(14),
                ),
                child: Row(
                  children: [
                    const Icon(
                      Icons.menu_book_rounded,
                      size: 18,
                      color: JellyTheme.primary,
                    ),
                    const SizedBox(width: 8),
                    Text(
                      '今日下载  $used / $limit 本',
                      style: TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                        color: isDark
                            ? Colors.white70
                            : JellyTheme.textPrimaryLight,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 12),
              // 退出后回退提示
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Icon(
                    Icons.info_outline_rounded,
                    size: 15,
                    color: JellyTheme.accent,
                  ),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      '退出后将回退内置账号（${ZlibraryService.builtinDailyLimit} 本/天）',
                      style: const TextStyle(
                        fontSize: 12,
                        color: JellyTheme.textSecondary,
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 18),
              // 按钮区
              Row(
                children: [
                  Expanded(
                    child: SizedBox(
                      height: 44,
                      child: TextButton(
                        onPressed: () => Navigator.pop(ctx),
                        style: TextButton.styleFrom(
                          foregroundColor: JellyTheme.primary,
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(14),
                          ),
                        ),
                        child: const Text(
                          '取消',
                          style: TextStyle(
                            fontSize: 15,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: _LogoutButton(
                      onTap: () => Navigator.pop(ctx, 'logout'),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
    if (action == 'logout' && mounted) {
      await z.logout();
      _showTip('已退出登录');
    }
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Scaffold(
      appBar: widget.showBackButton
          ? AppBar(
              title: const Text('图书'),
              actions: [
                Padding(
                  padding: const EdgeInsets.only(right: 12),
                  child: Transform.translate(
                    offset: const Offset(0, 4),
                    child: _buildAvatar(isDark),
                  ),
                ),
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
            child: Padding(
              padding: const EdgeInsets.fromLTRB(12, 6, 12, 8),
              child: Column(
                children: [
                  // 标题 + 头像（AppBar 模式下由 AppBar 承担，头像移入 AppBar.actions）
                  if (!widget.showBackButton)
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Padding(
                          padding: const EdgeInsets.only(left: 4),
                          child: Text(
                            '图书',
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
                        _buildAvatar(isDark),
                      ],
                    ),
                  const SizedBox(height: 8),
                  // 搜索框 + 视图切换
                  Row(
                    children: [
                      const Spacer(),
                      SizedBox(
                        width: MediaQuery.of(context).size.width * 0.5,
                        child: JellySearchBar(
                          controller: _searchController,
                          hintText: '搜索图书',
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
                  const SizedBox(height: 8),
                  // 格式小标签（常见类型）
                  _buildFormatChips(isDark),
                ],
              ),
            ),
          ),
          Expanded(child: _buildBody()),
        ],
      ),
    );
  }

  /// 右上角头像（登录态显示用户图标，未登录显示登录图标）
  Widget _buildAvatar(bool isDark) {
    final z = ZlibraryService();
    final logged = z.isLoggedIn;
    // 登录态：限额优先用服务端实际值（/eapi/user/profile），未取到回退硬编码
    final limit = z.isLoggedIn
        ? (z.serverDownloadsLimit ?? ZlibraryService.loggedDailyLimit)
        : ZlibraryService.builtinDailyLimit;
    final used = z.isLoggedIn ? z.loggedCountToday : z.builtinCountToday;
    return Column(
      children: [
        Material(
          color: logged
              ? JellyTheme.primary
              : (isDark ? JellyTheme.cardDark : Colors.white),
          shape: const CircleBorder(),
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            onTap: _onAvatarTap,
            child: SizedBox(
              width: 36,
              height: 36,
              child: Center(
                child: logged
                    ? Image.asset(
                        'assets/icons/user.png',
                        width: 30,
                        height: 30,
                        fit: BoxFit.cover,
                        errorBuilder: (_, _, _) => Icon(
                          Icons.person_rounded,
                          color: Colors.white,
                          size: 20,
                        ),
                      )
                    : Icon(
                        Icons.person_rounded,
                        color: isDark ? Colors.white70 : JellyTheme.primary,
                        size: 20,
                      ),
              ),
            ),
          ),
        ),
        const SizedBox(height: 2),
        Text(
          logged ? '$used/$limit' : '未登录',
          style: TextStyle(
            fontSize: 9,
            color: isDark ? Colors.white54 : JellyTheme.textSecondary,
          ),
        ),
      ],
    );
  }

  /// 格式小标签（常见类型，整体水平居中；超出可横向滚动）
  Widget _buildFormatChips(bool isDark) {
    final chips = <Widget>[];
    for (var i = 0; i < BookFormat.common.length; i++) {
      if (i > 0) chips.add(const SizedBox(width: 8));
      chips.add(_buildFormatChip(BookFormat.common[i], isDark));
    }
    return LayoutBuilder(
      builder: (context, constraints) {
        return SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          // 上下留白，避免标签阴影被裁切
          padding: const EdgeInsets.symmetric(vertical: 8),
          child: ConstrainedBox(
            constraints: BoxConstraints(minWidth: constraints.maxWidth),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              mainAxisSize: MainAxisSize.max,
              children: chips,
            ),
          ),
        );
      },
    );
  }

  Widget _buildFormatChip(BookFormat f, bool isDark) {
    final selected = (f.value ?? '') == _format;
    return GestureDetector(
      onTap: () {
        setState(() => _format = f.value ?? '');
        // 有关键词时切换格式自动重新搜索
        if (_keyword.trim().isNotEmpty) {
          _doSearch();
        }
      },
      child: Container(
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
        child: Text(
          f.label,
          style: TextStyle(
            fontSize: 12,
            fontWeight: FontWeight.w600,
            color: selected
                ? Colors.white
                : (isDark ? Colors.white70 : JellyTheme.textSecondary),
          ),
        ),
      ),
    );
  }

  /// 悬浮返回顶部按钮
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
    if (_showHistory) return _buildHistory();

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

    // 搜索异常
    if (_errorMsg != null && _result.items.isEmpty) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Icon(Icons.cloud_off_rounded, size: 64, color: Colors.grey),
            const SizedBox(height: 16),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 32),
              child: Text(
                _errorMsg!,
                textAlign: TextAlign.center,
                style: const TextStyle(color: Colors.grey),
              ),
            ),
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
            Text('没有找到相关图书', style: TextStyle(color: Colors.grey)),
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
            Icon(Icons.book_rounded, size: 64, color: Colors.grey),
            SizedBox(height: 16),
            Text('输入关键词开始搜索图书', style: TextStyle(color: Colors.grey)),
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

  Key _entranceKey(int index, {required bool isGrid}) =>
      ValueKey('${isGrid}_${_searchSession}_$index');

  int _adaptiveColumns(
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
            final book = _result.items[index];
            return StaggeredEntrance(
              key: _entranceKey(index, isGrid: true),
              index: index,
              child: JellyBookCard(
                book: book,
                isGrid: true,
                heroTag: bookCoverHeroTag('search', book),
                onTap: () => _openDetail(book),
              ),
            );
          },
        );
      },
    );
  }

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
            final book = _result.items[index];
            return StaggeredEntrance(
              key: _entranceKey(index, isGrid: false),
              index: index,
              child: JellyBookCard(
                book: book,
                isGrid: false,
                heroTag: bookCoverHeroTag('search', book),
                onTap: () => _openDetail(book),
              ),
            );
          },
        );
      },
    );
  }
}

/// 退出登录按钮：危险色实心 + 按压缩放反馈
class _LogoutButton extends StatefulWidget {
  final VoidCallback onTap;
  const _LogoutButton({required this.onTap});

  @override
  State<_LogoutButton> createState() => _LogoutButtonState();
}

class _LogoutButtonState extends State<_LogoutButton> {
  bool _pressed = false;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTapDown: (_) => setState(() => _pressed = true),
      onTapUp: (_) => setState(() => _pressed = false),
      onTapCancel: () => setState(() => _pressed = false),
      onTap: widget.onTap,
      child: AnimatedScale(
        scale: _pressed ? 0.97 : 1.0,
        duration: const Duration(milliseconds: 120),
        curve: Curves.easeOut,
        child: Container(
          height: 44,
          decoration: BoxDecoration(
            color: JellyTheme.error,
            borderRadius: BorderRadius.circular(14),
          ),
          child: const Center(
            child: Text(
              '退出登录',
              style: TextStyle(
                fontSize: 15,
                fontWeight: FontWeight.w700,
                color: Colors.white,
              ),
            ),
          ),
        ),
      ),
    );
  }
}
