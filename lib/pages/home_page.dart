import 'package:flutter/material.dart';

import '../services/remote_config_service.dart';
import '../services/settings_service.dart';
import '../services/update_service.dart';
import '../widgets/bookshelf_icon.dart';
import '../widgets/jelly_nav_bar.dart';
import '../widgets/notification_popup.dart';
import '../widgets/update_dialog.dart';
import 'book_search_page.dart';
import 'bookshelf_page.dart';
import 'favorites_page.dart';
import 'me_page.dart';
import 'search_page.dart';

/// 主页面（果冻风底部导航）
class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  bool _updateDialogShown = false; // 防止重复弹窗
  late NavTab _currentTab; // 当前选中的 tab

  // NavTab 与导航项、页面的映射
  static final Map<NavTab, JellyNavItem> _tabNavItems = {
    NavTab.manga: JellyNavItem(icon: Icons.palette_rounded, label: '漫画'),
    NavTab.book: JellyNavItem(icon: Icons.book_rounded, label: '图书'),
    NavTab.bookshelf: JellyNavItem(
      iconBuilder: (color, size) => BookshelfIcon(color: color, size: size),
      label: '书架',
    ),
    NavTab.favorites: JellyNavItem(icon: Icons.favorite_rounded, label: '收藏'),
    NavTab.me: JellyNavItem(icon: Icons.person_rounded, label: '我的'),
  };

  @override
  void initState() {
    super.initState();
    _currentTab = SettingsService().defaultHomePage.toNavTab();
    // 监听设置变化（默认首页、可见 tab 变化时响应）
    SettingsService().addListener(_onSettingsChanged);
    // 监听 RemoteConfigService 的版本检测结果，有新版本时弹窗
    RemoteConfigService().addListener(_onRemoteConfigChanged);
    // 首帧后检查一次（可能 init 时后台检测已完成）
    WidgetsBinding.instance.addPostFrameCallback((_) => _maybeShowUpdate());
  }

  @override
  void dispose() {
    SettingsService().removeListener(_onSettingsChanged);
    RemoteConfigService().removeListener(_onRemoteConfigChanged);
    super.dispose();
  }

  void _onSettingsChanged() {
    final visible = SettingsService().visibleNavTabs;
    if (!visible.contains(_currentTab)) {
      // 当前 tab 被隐藏，切到第一个可见 tab
      setState(() => _currentTab = visible.first);
    }
  }

  void _onRemoteConfigChanged() {
    _maybeShowUpdate();
  }

  /// 有新版本且未弹窗过，则弹窗
  void _maybeShowUpdate() {
    if (!mounted || _updateDialogShown) return;
    final service = RemoteConfigService();
    if (!service.hasNewVersion || service.latestVersion == null) return;

    _updateDialogShown = true;
    final result = UpdateResult(
      hasUpdate: true,
      latestVersion: service.latestVersion,
      releaseUrl: service.releaseUrl,
      releaseBody: service.releaseBody,
    );
    showUpdateAvailableDialog(context, result);
  }

  // 根据 tab 构建对应页面（isActive 由当前选中状态决定）
  Widget _buildPageFor(NavTab tab, bool isActive) {
    switch (tab) {
      case NavTab.manga:
        return SearchPage(isActive: isActive);
      case NavTab.book:
        return BookSearchPage(isActive: isActive);
      case NavTab.favorites:
        return FavoritesPage(isActive: isActive);
      case NavTab.bookshelf:
        return BookshelfPage(isActive: isActive);
      case NavTab.me:
        return MePage(isActive: isActive);
    }
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: SettingsService(),
      builder: (context, _) {
        final visible = SettingsService().visibleNavTabs;
        // 保险：确保 _currentTab 在可见列表中
        if (!visible.contains(_currentTab)) {
          _currentTab = visible.first;
        }
        final currentIndex = visible.indexOf(_currentTab);

        final navItems = visible
            .map((t) => _tabNavItems[t]!)
            .toList(growable: false);
        final pages = visible
            .map((t) => _buildPageFor(t, t == _currentTab))
            .toList(growable: false);

        final floating = SettingsService().navFloating;

        return Scaffold(
          // 悬浮模式：extendBody 让内容延伸到底部，导航栏浮在内容上方
          extendBody: floating,
          body: Column(
            children: [
              const NotificationPopup(),
              Expanded(
                child: IndexedStack(index: currentIndex, children: pages),
              ),
            ],
          ),
          // 果冻风底部导航（支持悬浮胶囊样式）
          bottomNavigationBar: JellyNavBar(
            currentIndex: currentIndex,
            floating: floating,
            onTap: (index) {
              setState(() => _currentTab = visible[index]);
            },
            items: navItems,
          ),
        );
      },
    );
  }
}
