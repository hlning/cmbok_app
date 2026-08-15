import 'package:flutter/material.dart';
import '../services/book_view_mode.dart';
import '../services/settings_service.dart';
import '../services/view_mode.dart';
import '../theme/jelly_theme.dart';
import '../widgets/bookshelf_icon.dart';
import '../widgets/jelly_segmented_toggle.dart';

/// 显示设置页：漫画/图书搜索页视图 + 启动默认首页。
/// 与搜索页右上角的视图切换共用 ViewMode / BookViewMode，二者同步并持久化。
class DisplaySettingsPage extends StatefulWidget {
  const DisplaySettingsPage({super.key});

  @override
  State<DisplaySettingsPage> createState() => _DisplaySettingsPageState();
}

class _DisplaySettingsPageState extends State<DisplaySettingsPage>
    with TickerProviderStateMixin {
  late final TabController _mangaViewCtrl;
  late final TabController _bookViewCtrl;
  bool _mangaViewAnimating = false;
  bool _bookViewAnimating = false;

  @override
  void initState() {
    super.initState();
    _mangaViewCtrl = TabController(
      length: 2,
      vsync: this,
      initialIndex: ViewMode().isGrid ? 0 : 1,
    );
    _bookViewCtrl = TabController(
      length: 2,
      vsync: this,
      initialIndex: BookViewMode().isGrid ? 0 : 1,
    );
  }

  @override
  void dispose() {
    _mangaViewCtrl.dispose();
    _bookViewCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Scaffold(
      appBar: AppBar(title: const Text('显示设置')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          _buildCard(
            isDark,
            title: '启动默认首页',
            subtitle: 'App 启动时直接进入的页面',
            trailing: ListenableBuilder(
              listenable: SettingsService(),
              builder: (context, _) => _buildHomeDropdown(isDark),
            ),
          ),
          const SizedBox(height: 12),
          // 悬浮导航栏开关（第二位）
          ListenableBuilder(
            listenable: SettingsService(),
            builder: (context, _) => _buildFloatingNavBarCard(isDark),
          ),
          const SizedBox(height: 12),
          // 导航栏显示设置（第三位）
          ListenableBuilder(
            listenable: SettingsService(),
            builder: (context, _) => _buildNavBarVisibilityCard(isDark),
          ),
          const SizedBox(height: 12),
          // 页面分类跟随导航栏开关
          ListenableBuilder(
            listenable: SettingsService(),
            builder: (context, _) => _buildPageTabsFollowNavCard(isDark),
          ),
          const SizedBox(height: 12),
          // 默认显示内容（漫画/图书）
          ListenableBuilder(
            listenable: SettingsService(),
            builder: (context, _) => _buildDefaultContentCard(isDark),
          ),
          const SizedBox(height: 12),
          _buildCard(
            isDark,
            title: '漫画搜索页视图',
            subtitle: '漫画搜索与漫画收藏页的卡片布局',
            trailing: ListenableBuilder(
              listenable: ViewMode(),
              builder: (context, _) {
                final target = ViewMode().isGrid ? 0 : 1;
                if (!_mangaViewAnimating && _mangaViewCtrl.index != target) {
                  _mangaViewCtrl.animateTo(target);
                }
                return AnimatedBuilder(
                  animation: _mangaViewCtrl.animation!,
                  builder: (context, _) => JellySegmentedToggle(
                    index: _mangaViewCtrl.animation!.value,
                    onChanged: (i) {
                      _mangaViewAnimating = true;
                      _mangaViewCtrl.animateTo(i);
                      ViewMode().set(i == 0);
                      Future.delayed(const Duration(milliseconds: 320), () {
                        if (mounted) _mangaViewAnimating = false;
                      });
                    },
                    segments: const [
                      JellySegmentData(icon: Icons.grid_view_rounded),
                      JellySegmentData(icon: Icons.view_list_rounded),
                    ],
                  ),
                );
              },
            ),
          ),
          const SizedBox(height: 12),
          _buildCard(
            isDark,
            title: '图书搜索页视图',
            subtitle: '图书搜索与图书收藏页的卡片布局',
            trailing: ListenableBuilder(
              listenable: BookViewMode(),
              builder: (context, _) {
                final target = BookViewMode().isGrid ? 0 : 1;
                if (!_bookViewAnimating && _bookViewCtrl.index != target) {
                  _bookViewCtrl.animateTo(target);
                }
                return AnimatedBuilder(
                  animation: _bookViewCtrl.animation!,
                  builder: (context, _) => JellySegmentedToggle(
                    index: _bookViewCtrl.animation!.value,
                    onChanged: (i) {
                      _bookViewAnimating = true;
                      _bookViewCtrl.animateTo(i);
                      BookViewMode().set(i == 0);
                      Future.delayed(const Duration(milliseconds: 320), () {
                        if (mounted) _bookViewAnimating = false;
                      });
                    },
                    segments: const [
                      JellySegmentData(icon: Icons.grid_view_rounded),
                      JellySegmentData(icon: Icons.view_list_rounded),
                    ],
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  /// 悬浮导航栏开关卡片
  Widget _buildFloatingNavBarCard(bool isDark) {
    final s = SettingsService();
    return _buildCard(
      isDark,
      title: '悬浮导航栏',
      subtitle: '胶囊型毛玻璃悬浮样式，关闭为底部固定样式',
      trailing: Switch(
        value: s.navFloating,
        onChanged: (v) => s.setNavFloating(v),
        activeColor: JellyTheme.primary,
      ),
    );
  }

  /// 导航栏显示设置卡片（多行开关）
  Widget _buildNavBarVisibilityCard(bool isDark) {
    final s = SettingsService();
    final visible = s.visibleNavTabs.toSet();
    final contentTabs = <(NavTab, Widget Function(Color, double), String)>[
      (
        NavTab.manga,
        (c, s) => Icon(Icons.palette_rounded, color: c, size: s),
        '漫画',
      ),
      (
        NavTab.book,
        (c, s) => Icon(Icons.book_rounded, color: c, size: s),
        '图书',
      ),
      (NavTab.bookshelf, (c, s) => BookshelfIcon(color: c, size: s), '书架'),
      (
        NavTab.favorites,
        (c, s) => Icon(Icons.favorite_rounded, color: c, size: s),
        '收藏',
      ),
    ];
    // 内容类 tab 中已选的数量，用于判断最后一个不可取消
    final selectedContentCount = contentTabs
        .where((t) => visible.contains(t.$1))
        .length;

    return Container(
      decoration: BoxDecoration(
        color: isDark ? JellyTheme.cardDark : JellyTheme.cardLight,
        borderRadius: BorderRadius.circular(16),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // 卡片标题
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 14, 16, 4),
            child: Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        '导航栏显示',
                        style: TextStyle(
                          fontSize: 15,
                          fontWeight: FontWeight.bold,
                          color: isDark
                              ? Colors.white
                              : JellyTheme.textPrimaryLight,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        '自定义底部导航栏显示的页面（"我的"固定显示）',
                        style: TextStyle(
                          fontSize: 12,
                          color: JellyTheme.textSecondary,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          // 内容类 tab 开关
          ...contentTabs.map((t) {
            final selected = visible.contains(t.$1);
            // 只剩一个内容类 tab 时不可取消
            final disabled = selected && selectedContentCount <= 1;
            return _buildSwitchRow(
              isDark,
              icon: t.$2,
              label: t.$3,
              value: selected,
              disabled: disabled,
              onChanged: (v) {
                final newList = <NavTab>{...visible};
                if (v) {
                  newList.add(t.$1);
                } else {
                  newList.remove(t.$1);
                }
                s.setVisibleNavTabs(newList.toList());
              },
            );
          }),
          // "我的"固定显示
          _buildSwitchRow(
            isDark,
            icon: (c, s) => Icon(Icons.person_rounded, color: c, size: s),
            label: '我的',
            value: true,
            disabled: true,
            onChanged: (_) {},
          ),
          const SizedBox(height: 8),
        ],
      ),
    );
  }

  /// 页面分类跟随导航栏开关卡片
  Widget _buildPageTabsFollowNavCard(bool isDark) {
    final s = SettingsService();
    return _buildCard(
      isDark,
      title: '页面分类跟随导航栏',
      subtitle: '收藏/书架/下载页隐藏导航栏已关闭的漫画或图书分类',
      trailing: Switch(
        value: s.pageTabsFollowNav,
        onChanged: (v) => s.setPageTabsFollowNav(v),
        activeColor: JellyTheme.primary,
      ),
    );
  }

  /// 默认显示内容卡片（漫画/图书切换）
  Widget _buildDefaultContentCard(bool isDark) {
    final s = SettingsService();
    return _buildCard(
      isDark,
      title: '默认显示',
      subtitle: '收藏/书架/下载页进入时默认显示的分类',
      trailing: JellySegmentedToggle(
        index: s.pageDefaultContent == PageDefaultContent.manga ? 0.0 : 1.0,
        onChanged: (i) {
          s.setPageDefaultContent(
            i == 0 ? PageDefaultContent.manga : PageDefaultContent.book,
          );
        },
        segments: const [
          JellySegmentData(icon: Icons.palette_rounded, label: '漫画'),
          JellySegmentData(icon: Icons.book_rounded, label: '图书'),
        ],
      ),
    );
  }

  /// 单行开关：左图标+文字，右 Switch
  Widget _buildSwitchRow(
    bool isDark, {
    required Widget Function(Color, double) icon,
    required String label,
    required bool value,
    required bool disabled,
    required ValueChanged<bool> onChanged,
  }) {
    final fgColor = disabled
        ? (isDark ? Colors.white38 : Colors.black38)
        : (isDark ? Colors.white : JellyTheme.textPrimaryLight);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 2),
      child: Row(
        children: [
          icon(fgColor, 18),
          const SizedBox(width: 10),
          Expanded(
            child: Text(label, style: TextStyle(fontSize: 14, color: fgColor)),
          ),
          Switch(
            value: value,
            onChanged: disabled ? null : onChanged,
            activeColor: JellyTheme.primary,
          ),
        ],
      ),
    );
  }

  /// 启动默认首页下拉选择（仅显示当前可见的 tab）
  Widget _buildHomeDropdown(bool isDark) {
    final s = SettingsService();
    final icons = <NavTab, Widget Function(Color, double)>{
      NavTab.manga: (c, s) => Icon(Icons.palette_rounded, color: c, size: s),
      NavTab.book: (c, s) => Icon(Icons.book_rounded, color: c, size: s),
      NavTab.bookshelf: (c, s) => BookshelfIcon(color: c, size: s),
      NavTab.favorites: (c, s) =>
          Icon(Icons.favorite_rounded, color: c, size: s),
      NavTab.me: (c, s) => Icon(Icons.person_rounded, color: c, size: s),
    };
    const labels = <NavTab, String>{
      NavTab.manga: '漫画',
      NavTab.book: '图书',
      NavTab.bookshelf: '书架',
      NavTab.favorites: '收藏',
      NavTab.me: '我的',
    };
    final visible = s.visibleNavTabs;
    final currentTab = s.defaultHomePage.toNavTab();
    return DropdownButton<NavTab>(
      value: visible.contains(currentTab) ? currentTab : visible.first,
      underline: const SizedBox(),
      isDense: true,
      style: TextStyle(
        fontSize: 14,
        fontWeight: FontWeight.w600,
        color: isDark ? Colors.white : JellyTheme.textPrimaryLight,
      ),
      dropdownColor: isDark ? JellyTheme.cardDark : Colors.white,
      items: visible
          .map(
            (t) => DropdownMenuItem(
              value: t,
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  icons[t]!(JellyTheme.primary, 18),
                  const SizedBox(width: 6),
                  Text(labels[t]!),
                ],
              ),
            ),
          )
          .toList(),
      onChanged: (v) {
        if (v != null) {
          s.setDefaultHomePage(v.toDefaultHomePage());
        }
      },
    );
  }

  /// 通用设置卡片：左侧标题+副标题，右侧控件
  Widget _buildCard(
    bool isDark, {
    required String title,
    required String subtitle,
    required Widget trailing,
  }) {
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 14, 8, 14),
      decoration: BoxDecoration(
        color: isDark ? JellyTheme.cardDark : JellyTheme.cardLight,
        borderRadius: BorderRadius.circular(16),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  title,
                  style: TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.bold,
                    color: isDark ? Colors.white : JellyTheme.textPrimaryLight,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  subtitle,
                  style: TextStyle(
                    fontSize: 12,
                    color: JellyTheme.textSecondary,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          trailing,
        ],
      ),
    );
  }
}
