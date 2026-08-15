import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';
import 'package:url_launcher/url_launcher.dart';
import '../services/platform_service.dart';
import '../services/settings_service.dart';
import '../services/theme_switch.dart';
import '../services/update_service.dart';
import '../theme/jelly_palette.dart';
import '../theme/jelly_theme.dart';
import '../utils/constants.dart';
import '../widgets/bookshelf_icon.dart';
import '../widgets/jelly_nav_bar.dart';
import '../widgets/staggered_entrance.dart';
import '../widgets/update_dialog.dart';
import 'about_page.dart';
import 'book_search_page.dart';
import 'bookshelf_page.dart';
import 'browse_history_page.dart';
import 'custom_theme_editor_page.dart';
import 'display_settings_page.dart';
import 'download_page.dart';
import 'download_settings_page.dart';
import 'favorites_page.dart';
import 'reading_settings_page.dart';
import 'search_page.dart';
import 'source_repo_page.dart';

/// "我的"页：菜单（下载设置等）+ 右上角暗色模式切换 + 版本信息
class MePage extends StatefulWidget {
  final bool isActive;

  const MePage({super.key, this.isActive = false});

  @override
  State<MePage> createState() => _MePageState();
}

class _MePageState extends State<MePage> {
  int _session = 0; // 首次切到"我的" tab 时 +1，触发卡片入场动画
  bool _hasShownEntrance = false; // 是否已播过首次入场动画
  final GlobalKey _themeToggleKey = GlobalKey(); // 暗色模式切换按钮（量取圆形扩散动画起点）
  String? _switchingTo; // 主题切换中（主题风格面板内 loading 遮罩用）

  @override
  void didUpdateWidget(covariant MePage oldWidget) {
    super.didUpdateWidget(oldWidget);
    // 仅首次切到"我的" tab 时重播入场动画，之后切回不再触发（避免闪烁）
    if (widget.isActive && !oldWidget.isActive && !_hasShownEntrance) {
      _hasShownEntrance = true;
      setState(() => _session++);
    }
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final titleColor = isDark ? Colors.white : JellyTheme.textPrimaryLight;
    // 导航栏被隐藏的 tab（在"下载记录"下方依次补入口）
    final hiddenTabs = NavTab.values
        .where(
          (t) =>
              t != NavTab.me && !SettingsService().visibleNavTabs.contains(t),
        )
        .toList();
    final hc = hiddenTabs.length;
    return Scaffold(
      backgroundColor: Colors.transparent,
      body: SafeArea(
        bottom: false,
        child: ListView(
          padding: EdgeInsets.only(
            left: 12,
            right: 12,
            top: 0,
            bottom:
                8 +
                (SettingsService().navFloating
                    ? JellyNavBar.floatingTotalHeight + 8
                    : 0.0),
          ),
          children: [
            // 标题 + 右上角暗色模式切换
            Padding(
              padding: const EdgeInsets.only(top: 6, bottom: 12),
              child: Row(
                children: [
                  Padding(
                    padding: const EdgeInsets.only(left: 4),
                    child: Text(
                      '我的',
                      style: TextStyle(
                        fontSize: 22,
                        fontWeight: FontWeight.bold,
                        color: titleColor,
                      ),
                    ),
                  ),
                  const Spacer(),
                  _buildThemeToggle(isDark),
                ],
              ),
            ),
            LayoutBuilder(
              builder: (context, constraints) {
                final cols = _adaptiveCols(constraints.maxWidth);
                const spacing = 12.0;
                final itemWidth =
                    (constraints.maxWidth - spacing * (cols - 1)) / cols;
                return Wrap(
                  spacing: spacing,
                  runSpacing: spacing,
                  children: [
                    StaggeredEntrance(
                      key: ValueKey('${_session}_0'),
                      index: 0,
                      child: SizedBox(
                        width: itemWidth,
                        child: ListenableBuilder(
                          listenable: SettingsService(),
                          builder: (context, _) => _buildSwitchTile(
                            isDark,
                            icon: Icons.lock_person_rounded,
                            iconBg: JellyTheme.primary,
                            title: '图书使用内置账号',
                            subtitle: '关闭后需登录才能下载',
                            value: SettingsService().useBuiltinAccount,
                            onChanged: SettingsService().setUseBuiltinAccount,
                          ),
                        ),
                      ),
                    ),
                    StaggeredEntrance(
                      key: ValueKey('${_session}_1'),
                      index: 1,
                      child: SizedBox(
                        width: itemWidth,
                        child: ListenableBuilder(
                          listenable: SettingsService(),
                          builder: (context, _) => _buildSwitchTile(
                            isDark,
                            icon: Icons.system_update_rounded,
                            iconBg: JellyTheme.primary,
                            title: '启动检查更新',
                            subtitle: '仅新版本才弹窗提示',
                            value: SettingsService().checkUpdateOnStartup,
                            onChanged:
                                SettingsService().setCheckUpdateOnStartup,
                          ),
                        ),
                      ),
                    ),
                    StaggeredEntrance(
                      key: ValueKey('${_session}_theme_follow'),
                      index: 2,
                      child: SizedBox(
                        width: itemWidth,
                        child: ListenableBuilder(
                          listenable: SettingsService(),
                          builder: (context, _) => _buildSwitchTile(
                            isDark,
                            icon: Icons.brightness_auto_rounded,
                            iconBg: JellyTheme.primary,
                            title: '主题跟随系统',
                            subtitle: '随系统明暗自动切换',
                            value: SettingsService().themeFollowSystem,
                            onChanged: SettingsService().setThemeFollowSystem,
                          ),
                        ),
                      ),
                    ),
                    StaggeredEntrance(
                      key: ValueKey('${_session}_theme_style'),
                      index: 3,
                      child: SizedBox(
                        width: itemWidth,
                        child: ListenableBuilder(
                          listenable: SettingsService(),
                          builder: (context, _) {
                            return _buildMenuItem(
                              isDark,
                              icon: Icons.palette_rounded,
                              iconBg: JellyTheme.primary,
                              title: '主题风格',
                              subtitle:
                                  '当前：${SettingsService().currentThemeInfo.name}',
                              onTap: _showThemePresetSheet,
                            );
                          },
                        ),
                      ),
                    ),
                    StaggeredEntrance(
                      key: ValueKey('${_session}_4'),
                      index: 4,
                      child: SizedBox(
                        width: itemWidth,
                        child: _buildMenuItem(
                          isDark,
                          icon: Icons.auto_stories_rounded,
                          iconBg: JellyTheme.primary,
                          title: '阅读设置',
                          subtitle: '漫画阅读模式：翻页 / 拼页',
                          onTap: () => Navigator.push(
                            context,
                            MaterialPageRoute(
                              builder: (_) => const ReadingSettingsPage(),
                            ),
                          ),
                        ),
                      ),
                    ),
                    StaggeredEntrance(
                      key: ValueKey('${_session}_5'),
                      index: 5,
                      child: SizedBox(
                        width: itemWidth,
                        child: _buildMenuItem(
                          isDark,
                          icon: Icons.tune_rounded,
                          iconBg: JellyTheme.primary,
                          title: '显示设置',
                          subtitle: '漫画 / 图书搜索页视图',
                          onTap: () => Navigator.push(
                            context,
                            MaterialPageRoute(
                              builder: (_) => const DisplaySettingsPage(),
                            ),
                          ),
                        ),
                      ),
                    ),
                    // 漫画源仓库（启用/禁用源 + 云端配置）
                    StaggeredEntrance(
                      key: ValueKey('${_session}_source_repo'),
                      index: 6,
                      child: SizedBox(
                        width: itemWidth,
                        child: _buildMenuItem(
                          isDark,
                          icon: Icons.source_rounded,
                          iconBg: JellyTheme.primary,
                          title: '漫画源仓库',
                          subtitle: '启用源 · 云端配置',
                          onTap: () => Navigator.push(
                            context,
                            MaterialPageRoute(
                              builder: (_) => const SourceRepoPage(),
                            ),
                          ),
                        ),
                      ),
                    ),
                    StaggeredEntrance(
                      key: ValueKey('${_session}_2'),
                      index: 7,
                      child: SizedBox(
                        width: itemWidth,
                        child: _buildMenuItem(
                          isDark,
                          icon: Icons.download_for_offline_rounded,
                          iconBg: JellyTheme.primary,
                          title: '下载设置',
                          subtitle: '同时下载量、分片并发量',
                          onTap: () => Navigator.push(
                            context,
                            MaterialPageRoute(
                              builder: (_) => const DownloadSettingsPage(),
                            ),
                          ),
                        ),
                      ),
                    ),
                    StaggeredEntrance(
                      key: ValueKey('${_session}_download_record'),
                      index: 8,
                      child: SizedBox(
                        width: itemWidth,
                        child: _buildMenuItem(
                          isDark,
                          icon: Icons.download_done_rounded,
                          iconBg: JellyTheme.primary,
                          title: '下载记录',
                          subtitle: '漫画 & 图书下载管理',
                          onTap: () => Navigator.push(
                            context,
                            MaterialPageRoute(
                              builder: (_) => const DownloadPage(
                                isActive: true,
                                showBackButton: true,
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                    StaggeredEntrance(
                      key: ValueKey('${_session}_browse_history'),
                      index: 9,
                      child: SizedBox(
                        width: itemWidth,
                        child: _buildMenuItem(
                          isDark,
                          icon: Icons.history_rounded,
                          iconBg: JellyTheme.primary,
                          title: '浏览记录',
                          subtitle: '漫画 & 图书浏览历史',
                          onTap: () => Navigator.push(
                            context,
                            MaterialPageRoute(
                              builder: (_) => const BrowseHistoryPage(),
                            ),
                          ),
                        ),
                      ),
                    ),
                    // 被隐藏导航 tab 入口（导航栏关闭某 tab 时，依次补在"下载记录"下方）
                    for (var i = 0; i < hiddenTabs.length; i++)
                      StaggeredEntrance(
                        key: ValueKey(
                          '${_session}_hidden_${hiddenTabs[i].name}',
                        ),
                        index: 9 + i,
                        child: SizedBox(
                          width: itemWidth,
                          child: _buildHiddenTabItem(isDark, hiddenTabs[i]),
                        ),
                      ),
                    StaggeredEntrance(
                      key: ValueKey('${_session}_6'),
                      index: 9 + hc,
                      child: SizedBox(
                        width: itemWidth,
                        child: _buildMenuItem(
                          isDark,
                          icon: Icons.update_rounded,
                          iconBg: JellyTheme.primary,
                          title: '检查更新',
                          subtitle: '获取 GitHub 最新版本',
                          onTap: _checkUpdate,
                        ),
                      ),
                    ),
                    StaggeredEntrance(
                      key: ValueKey('${_session}_7'),
                      index: 10 + hc,
                      child: SizedBox(
                        width: itemWidth,
                        child: _buildMenuItem(
                          isDark,
                          icon: Icons.info_outline_rounded,
                          iconBg: JellyTheme.primary,
                          title: '关于',
                          subtitle: '免责声明',
                          onTap: () => Navigator.push(
                            context,
                            MaterialPageRoute(
                              builder: (_) => const AboutPage(),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ],
                );
              },
            ),
            // 底部快捷区：GitHub / QQ群 / 分享软件（图标 + 文字）
            Padding(
              padding: const EdgeInsets.only(top: 16),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                children: [
                  StaggeredEntrance(
                    key: ValueKey('${_session}_8'),
                    index: 10 + hc,
                    child: _buildQuickAction(
                      isDark
                          ? 'assets/icons/github_dark.png'
                          : 'assets/icons/github.png',
                      Icons.code_rounded,
                      'GitHub',
                      () => _launchUrl(AppConstants.githubUrl),
                    ),
                  ),
                  StaggeredEntrance(
                    key: ValueKey('${_session}_9'),
                    index: 11 + hc,
                    child: _buildQuickAction(
                      'assets/icons/qq.png',
                      Icons.group_rounded,
                      'QQ群',
                      _openQqGroup,
                    ),
                  ),
                  StaggeredEntrance(
                    key: ValueKey('${_session}_10'),
                    index: 12 + hc,
                    child: _buildQuickAction(
                      'assets/icons/tt-station.png',
                      Icons.language_rounded,
                      '甜甜的小站',
                      () => _launchUrl(AppConstants.blogUrl),
                    ),
                  ),
                  StaggeredEntrance(
                    key: ValueKey('${_session}_11'),
                    index: 13 + hc,
                    child: _buildQuickAction(
                      'assets/icons/share.png',
                      Icons.share_rounded,
                      '分享软件',
                      _shareApp,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 12),
            StaggeredEntrance(
              key: ValueKey('${_session}_12'),
              index: 14 + hc,
              child: Center(
                child: Text(
                  '当前版本：${AppConstants.appName} V${AppConstants.version}',
                  style: TextStyle(
                    fontSize: 12,
                    color: JellyTheme.textSecondary,
                  ),
                ),
              ),
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }

  // -------------------- 暗色模式切换 --------------------

  /// 右上角明暗模式切换图标：暗色显太阳、亮色显月亮（内置图标），颜色区分明暗
  Widget _buildThemeToggle(bool isDark) {
    return ListenableBuilder(
      listenable: SettingsService(),
      builder: (context, _) {
        final dark = SettingsService().isDarkMode;
        return Material(
          key: _themeToggleKey,
          color: isDark ? JellyTheme.cardDark : Colors.white,
          shape: const CircleBorder(),
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            onTap: () {
              // 以图标中心作为主题切换圆形扩散动画的起点
              final ro = _themeToggleKey.currentContext?.findRenderObject();
              if (ro is RenderBox && ro.hasSize) {
                ThemeSwitch.origin = ro.localToGlobal(
                  ro.size.center(Offset.zero),
                );
              }
              final s = SettingsService();
              if (s.themeFollowSystem) {
                // 跟随系统时手动切换：退出跟随，并切到与当前生效相反的明暗
                s.setThemeFollowSystem(false);
                s.setDarkMode(!s.isDarkMode);
              } else {
                s.setDarkMode(!s.isDarkMode);
              }
            },
            child: SizedBox(
              width: 38,
              height: 38,
              child: Center(
                child: Icon(
                  dark ? Icons.light_mode_rounded : Icons.dark_mode_rounded,
                  size: 20,
                  color: dark ? Colors.amber.shade600 : Colors.indigo.shade400,
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  // -------------------- 检查更新 --------------------

  Future<void> _checkUpdate() async {
    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) =>
          Center(child: CircularProgressIndicator(color: JellyTheme.primary)),
    );
    final result = await UpdateService.check();
    if (!mounted) return;
    Navigator.of(context).pop(); // 关闭 loading

    if (result.error != null) {
      _toast(result.error!);
      return;
    }
    if (!result.hasUpdate) {
      _toast('已是最新版本 V${AppConstants.version}');
      return;
    }
    showUpdateAvailableDialog(context, result);
  }

  // -------------------- 分享软件 --------------------

  Future<void> _shareApp() async {
    final apkPath = await PlatformService.getApkPath();
    File? tmp;
    if (apkPath != null && await File(apkPath).exists()) {
      if (!mounted) return;
      // 复制到缓存目录（确保 share_plus 的 FileProvider 可访问）
      showDialog<void>(
        context: context,
        barrierDismissible: false,
        builder: (_) =>
            Center(child: CircularProgressIndicator(color: JellyTheme.primary)),
      );
      try {
        final tmpDir = await getTemporaryDirectory();
        tmp = File(
          '${tmpDir.path}/${AppConstants.appName}_V${AppConstants.version}.apk',
        );
        await tmp.writeAsBytes(await File(apkPath).readAsBytes(), flush: true);
      } catch (_) {
        tmp = null;
      }
      if (!mounted) return;
      Navigator.of(context).pop(); // 关闭 loading
    }
    if (!mounted) return;

    if (tmp != null && await tmp.exists()) {
      await Share.shareXFiles([
        XFile(tmp.path),
      ], subject: '${AppConstants.appName} V${AppConstants.version}');
    } else {
      await Share.share(
        '${AppConstants.appName} V${AppConstants.version} 下载地址：${AppConstants.shareUrl}',
      );
    }
  }

  // -------------------- 通用 --------------------

  Future<void> _launchUrl(String url) async {
    final uri = Uri.tryParse(url);
    if (uri == null) {
      _toast('链接无效');
      return;
    }
    final ok = await launchUrl(uri, mode: LaunchMode.externalApplication);
    if (!ok) _toast('无法打开链接');
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

  /// 打开 QQ 群名片（带加入按钮）；未安装 QQ 则复制群号
  Future<void> _openQqGroup() async {
    final uri = Uri.parse(
      'mqqapi://card/show_pslcard?src_type=internal&version=1&card_type=group&source=qrcode&uin=${AppConstants.qqGroupNumber}',
    );
    final launched = await launchUrl(uri, mode: LaunchMode.externalApplication);
    if (!launched) {
      await Clipboard.setData(ClipboardData(text: AppConstants.qqGroupNumber));
      _toast('未检测到QQ，已复制群号 ${AppConstants.qqGroupNumber}');
    }
  }

  /// 底部快捷区项：图标（assets/icons 彩色图标，缺省回退 Material 图标） + 文字
  Widget _buildQuickAction(
    String asset,
    IconData fallbackIcon,
    String label,
    VoidCallback onTap,
  ) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(12),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 44,
              height: 44,
              decoration: BoxDecoration(
                color: JellyTheme.primary.withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(14),
              ),
              child: Center(
                child: Image.asset(
                  asset,
                  width: 24,
                  height: 24,
                  errorBuilder: (_, _, _) =>
                      Icon(fallbackIcon, color: JellyTheme.primary, size: 22),
                ),
              ),
            ),
            const SizedBox(height: 6),
            Text(
              label,
              style: TextStyle(fontSize: 12, color: JellyTheme.textSecondary),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildMenuItem(
    bool isDark, {
    IconData? icon,
    JellyIconBuilder? iconBuilder,
    required Color iconBg,
    required String title,
    required String subtitle,
    required VoidCallback onTap,
  }) {
    assert(icon != null || iconBuilder != null);
    return Material(
      color: isDark ? JellyTheme.cardDark : JellyTheme.cardLight,
      borderRadius: BorderRadius.circular(16),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
          child: Row(
            children: [
              Container(
                width: 38,
                height: 38,
                decoration: BoxDecoration(
                  color: iconBg.withValues(alpha: 0.15),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: iconBuilder != null
                    ? iconBuilder(iconBg, 20)
                    : Icon(icon, color: iconBg, size: 20),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      style: TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w600,
                        color: isDark
                            ? Colors.white
                            : JellyTheme.textPrimaryLight,
                      ),
                    ),
                    const SizedBox(height: 2),
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
              Icon(
                Icons.chevron_right_rounded,
                color: isDark ? Colors.white38 : Colors.black26,
              ),
            ],
          ),
        ),
      ),
    );
  }

  // -------------------- 主题风格选择 --------------------

  /// 主题预设选择底部 sheet：3 套预设卡（名称 + 主色/强调色/背景色块），选中打勾
  void _showThemePresetSheet() {
    _switchingTo = null;
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      builder: (sheetCtx) {
        return StatefulBuilder(
          builder: (sheetCtx, setSheetState) {
            final isDark = Theme.of(sheetCtx).brightness == Brightness.dark;
            final switching = _switchingTo != null;
            return ListenableBuilder(
              listenable: SettingsService(),
              builder: (sheetCtx, _) {
                final current = SettingsService().themePreset;
                return Stack(
                  children: [
                    Container(
                      decoration: BoxDecoration(
                        color: isDark
                            ? JellyTheme.cardDark
                            : JellyTheme.cardLight,
                        borderRadius: const BorderRadius.vertical(
                          top: Radius.circular(24),
                        ),
                      ),
                      padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
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
                                color: isDark ? Colors.white24 : Colors.black12,
                                borderRadius: BorderRadius.circular(2),
                              ),
                            ),
                          ),
                          Row(
                            children: [
                              Text(
                                '主题风格',
                                style: TextStyle(
                                  fontSize: 18,
                                  fontWeight: FontWeight.w600,
                                  color: isDark
                                      ? Colors.white
                                      : JellyTheme.textPrimaryLight,
                                ),
                              ),
                              const Spacer(),
                              Text(
                                '省电',
                                style: TextStyle(
                                  fontSize: 13,
                                  color: isDark
                                      ? Colors.white70
                                      : Colors.black54,
                                ),
                              ),
                              Transform.scale(
                                scale: 0.75,
                                child: Switch(
                                  value: SettingsService().frameRateReduced,
                                  onChanged: switching
                                      ? null
                                      : (v) => SettingsService()
                                            .setFrameRateReduced(v),
                                ),
                              ),
                              const SizedBox(width: 6),
                              Text(
                                '动画',
                                style: TextStyle(
                                  fontSize: 13,
                                  color: isDark
                                      ? Colors.white70
                                      : Colors.black54,
                                ),
                              ),
                              Transform.scale(
                                scale: 0.75,
                                child: Switch(
                                  value: SettingsService().backgroundAnimation,
                                  onChanged: switching
                                      ? null
                                      : (v) => SettingsService()
                                            .setBackgroundAnimation(v),
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 12),
                          ConstrainedBox(
                            constraints: BoxConstraints(
                              maxHeight:
                                  MediaQuery.of(sheetCtx).size.height * 0.55,
                            ),
                            child: SingleChildScrollView(
                              child: Column(
                                mainAxisSize: MainAxisSize.min,
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  ...themePresets.map(
                                    (p) => _buildPresetCard(
                                      p,
                                      p.id == current,
                                      isDark,
                                      switching
                                          ? null
                                          : () async {
                                              setSheetState(
                                                () => _switchingTo = p.id,
                                              );
                                              await SettingsService()
                                                  .setThemePreset(p.id);
                                              // 等圆形揭示动画（截图+重建+扩散）完成，再收面板避免抢帧卡顿
                                              await Future.delayed(
                                                const Duration(
                                                  milliseconds: 500,
                                                ),
                                              );
                                              if (mounted)
                                                Navigator.pop(context);
                                            },
                                    ),
                                  ),
                                  if (SettingsService().customThemes.isNotEmpty)
                                    Padding(
                                      padding: const EdgeInsets.fromLTRB(
                                        4,
                                        10,
                                        4,
                                        6,
                                      ),
                                      child: Text(
                                        '我的自定义',
                                        style: TextStyle(
                                          fontSize: 13,
                                          color: JellyTheme.textSecondary,
                                        ),
                                      ),
                                    ),
                                  ...SettingsService().customThemes.map(
                                    (t) => _buildPresetCard(
                                      t,
                                      t.id == current,
                                      isDark,
                                      switching
                                          ? null
                                          : () async {
                                              setSheetState(
                                                () => _switchingTo = t.id,
                                              );
                                              await SettingsService()
                                                  .setThemePreset(t.id);
                                              await Future.delayed(
                                                const Duration(
                                                  milliseconds: 500,
                                                ),
                                              );
                                              if (mounted)
                                                Navigator.pop(context);
                                            },
                                      deletable: true,
                                      onDelete: () => _confirmDeleteCustom(t),
                                      editable: true,
                                      onEdit: () => _editCustom(t),
                                    ),
                                  ),
                                  const SizedBox(height: 8),
                                  _buildCreateThemeButton(isDark),
                                ],
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                    if (switching)
                      Positioned.fill(
                        child: AbsorbPointer(
                          child: Container(
                            decoration: BoxDecoration(
                              color: (isDark ? Colors.black : Colors.white)
                                  .withValues(alpha: 0.45),
                              borderRadius: const BorderRadius.vertical(
                                top: Radius.circular(24),
                              ),
                            ),
                            child: Center(
                              child: Column(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  CircularProgressIndicator(
                                    color: JellyTheme.primary,
                                  ),
                                  const SizedBox(height: 12),
                                  Text(
                                    '应用中...',
                                    style: TextStyle(
                                      fontSize: 14,
                                      color: isDark
                                          ? Colors.white70
                                          : JellyTheme.textPrimaryLight,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ),
                      ),
                  ],
                );
              },
            );
          },
        );
      },
    );
  }

  Widget _buildPresetCard(
    ThemePresetInfo preset,
    bool selected,
    bool isDark,
    VoidCallback? onTap, {
    bool deletable = false,
    VoidCallback? onDelete,
    bool editable = false,
    VoidCallback? onEdit,
  }) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Material(
        color: selected
            ? preset.palette.primary.withValues(alpha: 0.12)
            : (isDark
                  ? Colors.white.withValues(alpha: 0.04)
                  : Colors.black.withValues(alpha: 0.03)),
        borderRadius: BorderRadius.circular(16),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
            child: Row(
              children: [
                ...[
                  preset.palette.primary,
                  preset.palette.accent,
                  preset.palette.backgroundLight,
                ].map(
                  (c) => Container(
                    width: 28,
                    height: 28,
                    margin: const EdgeInsets.only(right: 8),
                    decoration: BoxDecoration(
                      color: c,
                      shape: BoxShape.circle,
                      border: Border.all(color: Colors.black12),
                    ),
                  ),
                ),
                const SizedBox(width: 4),
                Expanded(
                  child: Text(
                    preset.name,
                    style: TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.w600,
                      color: isDark
                          ? Colors.white
                          : JellyTheme.textPrimaryLight,
                    ),
                  ),
                ),
                if (editable && onEdit != null)
                  GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTap: onEdit,
                    child: Padding(
                      padding: const EdgeInsets.only(left: 4, right: 2),
                      child: Icon(
                        Icons.edit_outlined,
                        color: JellyTheme.textSecondary,
                        size: 20,
                      ),
                    ),
                  ),
                if (deletable)
                  GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTap: onDelete,
                    child: Padding(
                      padding: const EdgeInsets.only(left: 8, right: 6),
                      child: Icon(
                        Icons.close_rounded,
                        color: JellyTheme.textSecondary,
                        size: 20,
                      ),
                    ),
                  ),
                Icon(
                  selected
                      ? Icons.check_circle_rounded
                      : Icons.radio_button_unchecked_rounded,
                  color: selected
                      ? preset.palette.primary
                      : JellyTheme.textSecondary,
                  size: 22,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// 「新建自定义主题」按钮：跳转编辑器（保存后 addCustomTheme 已通知，sheet 自动刷新）
  Widget _buildCreateThemeButton(bool isDark) {
    return Padding(
      padding: const EdgeInsets.only(top: 4),
      child: Material(
        color: Colors.transparent,
        borderRadius: BorderRadius.circular(16),
        child: InkWell(
          borderRadius: BorderRadius.circular(16),
          onTap: () => Navigator.push(
            context,
            MaterialPageRoute(builder: (_) => const CustomThemeEditorPage()),
          ),
          child: Container(
            padding: const EdgeInsets.symmetric(vertical: 14),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(16),
              border: Border.all(
                color: JellyTheme.primary.withValues(alpha: 0.5),
                width: 1.5,
              ),
            ),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(Icons.add_rounded, color: JellyTheme.primary, size: 20),
                const SizedBox(width: 6),
                Text(
                  '新建自定义主题',
                  style: TextStyle(
                    color: JellyTheme.primary,
                    fontSize: 15,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// 删除自定义主题二次确认；删的若是当前主题，deleteCustomTheme 会回退 jelly 并触发动画
  Future<void> _confirmDeleteCustom(ThemePresetInfo t) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('删除主题'),
        content: Text('确定删除「${t.name}」？此操作不可撤销。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: TextButton.styleFrom(foregroundColor: JellyTheme.error),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (ok == true) {
      await SettingsService().deleteCustomTheme(t.id);
    }
  }

  /// 编辑自定义主题：打开编辑器（带 editing）。保存后 updateCustomTheme 通知，
  /// sheet 的 ListenableBuilder 自动刷新；当前主题的改动即时生效。
  void _editCustom(ThemePresetInfo t) {
    Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => CustomThemeEditorPage(editing: t)),
    );
  }

  /// 被隐藏导航 tab 的入口（导航栏关闭该 tab 时，在"我的"补入口）
  Widget _buildHiddenTabItem(bool isDark, NavTab tab) {
    switch (tab) {
      case NavTab.manga:
        return _buildMenuItem(
          isDark,
          icon: Icons.palette_rounded,
          iconBg: JellyTheme.primary,
          title: '漫画',
          subtitle: '漫画搜索与阅读',
          onTap: () => Navigator.push(
            context,
            MaterialPageRoute(
              builder: (_) =>
                  const SearchPage(isActive: true, showBackButton: true),
            ),
          ),
        );
      case NavTab.book:
        return _buildMenuItem(
          isDark,
          icon: Icons.book_rounded,
          iconBg: JellyTheme.primary,
          title: '图书',
          subtitle: '图书搜索与阅读',
          onTap: () => Navigator.push(
            context,
            MaterialPageRoute(
              builder: (_) =>
                  const BookSearchPage(isActive: true, showBackButton: true),
            ),
          ),
        );
      case NavTab.favorites:
        return _buildMenuItem(
          isDark,
          icon: Icons.favorite_rounded,
          iconBg: JellyTheme.primary,
          title: '收藏',
          subtitle: '漫画 & 图书收藏',
          onTap: () => Navigator.push(
            context,
            MaterialPageRoute(
              builder: (_) =>
                  const FavoritesPage(isActive: true, showBackButton: true),
            ),
          ),
        );
      case NavTab.bookshelf:
        return _buildMenuItem(
          isDark,
          iconBuilder: (color, size) => BookshelfIcon(color: color, size: size),
          iconBg: JellyTheme.primary,
          title: '书架',
          subtitle: '本地书架管理',
          onTap: () => Navigator.push(
            context,
            MaterialPageRoute(
              builder: (_) =>
                  const BookshelfPage(isActive: true, showBackButton: true),
            ),
          ),
        );
      case NavTab.me:
        return const SizedBox.shrink(); // 不会出现（me 始终可见）
    }
  }

  /// 开关设置行（左图标 + 标题/副标题 + 右侧 Switch），一层设置不跳子页面
  Widget _buildSwitchTile(
    bool isDark, {
    required IconData icon,
    required Color iconBg,
    required String title,
    required String subtitle,
    required bool value,
    required ValueChanged<bool> onChanged,
  }) {
    return Material(
      color: isDark ? JellyTheme.cardDark : JellyTheme.cardLight,
      borderRadius: BorderRadius.circular(16),
      clipBehavior: Clip.antiAlias,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        child: Row(
          children: [
            Container(
              width: 38,
              height: 38,
              decoration: BoxDecoration(
                color: iconBg.withValues(alpha: 0.15),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Icon(icon, color: iconBg, size: 20),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.w600,
                      color: isDark
                          ? Colors.white
                          : JellyTheme.textPrimaryLight,
                    ),
                  ),
                  const SizedBox(height: 2),
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
            Switch(value: value, onChanged: onChanged),
          ],
        ),
      ),
    );
  }

  /// 菜单卡片自适应列数：默认每行 1 个，宽度足够时自动增多
  int _adaptiveCols(double width) {
    var cols = (width / 360).floor();
    if (cols < 1) cols = 1;
    if (cols > 6) cols = 6;
    return cols;
  }
}
