import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../theme/jelly_palette.dart';
import '../theme/jelly_theme.dart';
import '../utils/constants.dart';

/// 日志工具
void _log(String message) {
  if (kDebugMode) {
    debugPrint('[Settings] $message');
  }
}

/// 漫画阅读模式：
/// - pageTurn：从右往左翻页（横向逐页，日漫方向，图片从右翻入）
/// - leftToRight：从左往右翻页（图片从左翻入）
/// - dissolve：消散（当前页淡出、下一页淡入）
/// - continuous：拼页（上下连续滚动）
/// - none：无动画（点击直接切换，不滑动；方向同 pageTurn）
/// 注：leftToRight 加在 dissolve 之后，none 追加末尾，保持旧持久化 index 不变。
enum ReadingMode { pageTurn, continuous, dissolve, leftToRight, none }

/// 图书阅读模式：翻页（左右平移）/ 仿真翻页（卷曲） / 覆盖（新页滑入覆盖当前页）
/// - vertical：上下翻页（纵向平移）
/// - none：无动画（点击直接切换，不滑动；方向同 pageTurn）
/// 注：vertical/none 追加末尾，保持旧持久化 index 不变。
enum BookReadingMode { pageTurn, simulation, cover, vertical, none }

/// 底部导航 tab 枚举（与导航栏顺序一致）
enum NavTab { manga, book, bookshelf, favorites, me }

/// 启动默认首页（对应底部导航 tab）
enum DefaultHomePage { manga, book, bookshelf, favorites, me }

/// 收藏/书架/下载三页默认显示的内容类型
enum PageDefaultContent { manga, book }

/// NavTab 与 DefaultHomePage 的双向转换辅助（两者值一一对应）
extension NavTabDefaultHomePageX on NavTab {
  DefaultHomePage toDefaultHomePage() => DefaultHomePage.values[index];
}

extension DefaultHomePageNavTabX on DefaultHomePage {
  NavTab toNavTab() => NavTab.values[index];
}

/// 应用设置服务（单例 + ChangeNotifier）
/// 持久化：
/// - 下载并发参数：同时下载量、分片并发量
/// - 下载保存位置（自定义目录；空 = 默认应用私有目录）
/// - 漫画章节合并 EPUB 及合并后是否保留图片
/// - 阅读模式：翻页 / 拼页
/// - 在线阅读预加载图片数
/// - 暗色模式（首次跟随系统，之后保留用户选择）
/// - 主题跟随系统（默认开启；开启时实时跟随系统明暗，关闭后用手动选择）
class SettingsService extends ChangeNotifier {
  SettingsService._();
  static final SettingsService _instance = SettingsService._();
  factory SettingsService() => _instance;

  static const _chaptersKey = 'download_max_concurrent_chapters';
  static const _imagesKey = 'download_max_concurrent_images';
  static const _readingModeKey = 'reading_mode';
  static const _preloadKey = 'reader_preload_image_count';
  static const _savePathKey = 'download_save_path';
  static const _mergeEpubKey = 'download_merge_epub';
  static const _keepImagesKey = 'download_keep_images_after_epub';
  static const _mergeChaptersCountKey = 'download_merge_chapters_count';
  static const _trimWhitespaceKey = 'download_trim_whitespace';
  static const _defaultHomeKey = 'default_home_page';
  static const _kBuiltinAccountKey = 'use_builtin_account';
  static const _kDarkModeKey = 'dark_mode';
  static const _kThemeFollowSystemKey = 'theme_follow_system';
  static const _kThemePresetKey = 'theme_preset'; // 主题预设：jelly/pink/green
  static const _kBgAnimationKey = 'background_animation'; // 主题背景动画开关
  static const _kFrameRateReducedKey = 'frame_rate_reduced'; // 主题动画降帧省电
  static const _kCustomThemesKey = 'custom_themes'; // 自定义主题（JSON 数组）
  static const _kCheckUpdateKey = 'check_update_on_startup';
  static const _kBookFontSizeKey = 'book_font_size';
  static const _kBookLineHeightKey = 'book_line_height';
  static const _kBookHorizontalPaddingKey = 'book_h_padding';
  static const _kBookVerticalPaddingKey = 'book_v_padding';
  static const _kBookReadingModeKey = 'book_reading_mode';
  // 图书正文字体覆盖：null = 跟随阅读模式（仿真→inkReadingKai，否则系统）；
  // 'system' = 强制系统字体；'inkReadingKai' = 内置楷体；其他 = 用户字体 family。
  static const _kBookFontFamilyKey = 'book_font_family';
  static const _kNavVisibleTabsKey = 'nav_visible_tabs';
  static const _kNavFloatingKey = 'nav_floating';
  static const _kNavOrderVersionKey =
      'nav_order_version'; // 导航 tab 顺序版本（v2: 书架与收藏互换）
  static const _kPageTabsFollowNavKey = 'page_tabs_follow_nav';
  static const _kPageDefaultContentKey = 'page_default_content';
  // 翻页按钮反转：左点下一页、右点上一页（默认关）
  static const _kReverseTapKey = 'reader_reverse_tap';
  // 双页模式：横屏左右并排两页（默认关，仅翻页模式生效）
  static const _kDoublePageKey = 'reader_double_page';
  // 阅读信息栏：阅读时角落显示时间/页码/进度等（默认开）
  static const _kShowReaderHudKey = 'reader_show_hud';
  // 音量键翻页：阅读时按音量上/下键翻页（默认关，会接管音量键）
  static const _kVolumeKeyTurnKey = 'reader_volume_key_turn';
  // 墨水屏模式：漫画黑白显示 + 柔和浅灰底（默认关）
  static const _kInkScreenModeKey = 'reader_ink_screen_mode';
  // 番茄钟：循环次数 / 每轮休息分钟
  static const _kPomodoroLoopCountKey = 'pomodoro_loop_count';
  static const _kPomodoroRestMinutesKey = 'pomodoro_rest_minutes';

  /// 同时下载量：默认 2，范围 1~5
  static const int minConcurrentChapters = 1;
  static const int maxConcurrentChaptersLimit = 5;
  static const int defaultConcurrentChapters = 2;

  /// 分片并发量：默认 10，范围 1~20
  static const int minConcurrentImages = 1;
  static const int maxConcurrentImagesLimit = 20;
  static const int defaultConcurrentImages = 10;

  /// 在线阅读预加载图片数：默认 5，范围 2~10
  static const int minPreloadImages = 2;
  static const int maxPreloadImages = 10;
  static const int defaultPreloadImages = 5;

  /// 番茄钟：工作时长固定 25 分钟（不可配）
  static const int pomodoroWorkMinutes = 25;

  /// 番茄钟循环次数：默认 1，范围 1~5
  static const int minPomodoroLoopCount = 1;
  static const int maxPomodoroLoopCount = 5;
  static const int defaultPomodoroLoopCount = 1;

  /// 番茄钟每轮休息分钟：默认 5，范围 1~15
  static const int minPomodoroRestMinutes = 1;
  static const int maxPomodoroRestMinutes = 15;
  static const int defaultPomodoroRestMinutes = 5;

  /// 图书排版：字号 / 行距 / 四周边距
  static const double defaultBookFontSize = 18;
  static const double minBookFontSize = 12;
  static const double maxBookFontSize = 28;
  static const double defaultBookLineHeight = 1.6;
  static const double minBookLineHeight = 1.2;
  static const double maxBookLineHeight = 3.0;
  static const double defaultBookHorizontalPadding = 16; // 图书左右边距
  static const double minBookHorizontalPadding = 15;
  static const double maxBookHorizontalPadding = 30;
  static const double defaultBookVerticalPadding = 36; // 图书上下边距
  static const double minBookVerticalPadding = 15;
  static const double maxBookVerticalPadding = 55;

  int _maxConcurrentChapters = defaultConcurrentChapters;
  int _maxConcurrentImages = defaultConcurrentImages;
  ReadingMode _readingMode = ReadingMode.pageTurn;
  BookReadingMode _bookReadingMode = BookReadingMode.pageTurn;
  String? _downloadSavePath;
  bool _mergeChapterToEpub = true;
  bool _keepImagesAfterEpub = true;
  int _mergeChaptersPerEpub = 1; // 每 N 话合并为一个 EPUB（1~20）
  bool _trimWhitespace = false; // 下载时去白边
  static const int minMergeChaptersPerEpub = 1;
  static const int maxMergeChaptersPerEpub = 20;
  DefaultHomePage _defaultHomePage = DefaultHomePage.manga;
  bool _useBuiltinAccount = true; // 图书下载未登录时是否回退内置账号（搜索一律回退内置账号）
  bool _checkUpdateOnStartup = true; // 启动时自动检查 app 新版本
  bool _isDarkMode = false; // 暗色模式（首次跟随系统，之后保留用户选择）
  bool _themeFollowSystem = true; // 主题跟随系统明暗；关闭后用上面的手动选择
  String _themePreset = 'jelly'; // 主题预设：jelly/pink/green 或 custom_*
  bool _backgroundAnimation = true; // 主题背景动画开关
  bool _frameRateReduced = true; // 主题动画降帧省电（默认开启，减半重绘）
  List<ThemePresetInfo> _customThemes =
      []; // 用户自定义主题（运行时镜像，持久化于 _kCustomThemesKey）
  int _preloadImageCount = defaultPreloadImages; // 在线阅读预加载图片数
  double _bookFontSize = defaultBookFontSize; // 图书字号
  double _bookLineHeight = defaultBookLineHeight; // 图书行距
  double _bookHorizontalPadding = defaultBookHorizontalPadding; // 图书左右边距
  double _bookVerticalPadding = defaultBookVerticalPadding; // 图书上下边距
  // 图书正文字体：null = 跟随阅读模式；其他含义见 _kBookFontFamilyKey 注释。
  String? _bookFontFamily;
  List<NavTab> _visibleNavTabs = NavTab.values.toList(); // 导航栏可见 tab，默认全显示
  bool _navFloating = true; // 导航栏是否悬浮（胶囊型毛玻璃样式），默认开启
  bool _pageTabsFollowNav = true; // 收藏/书架/下载页 tab 是否跟随导航栏 manga/book 可见性
  PageDefaultContent _pageDefaultContent =
      PageDefaultContent.manga; // 收藏/书架/下载页默认显示内容
  bool _reverseTap = false; // 翻页按钮反转（左下一、右上一）
  bool _doublePage = false; // 双页模式（横屏左右并排两页）
  bool _showReaderHud = true; // 阅读信息栏（时间/页码/进度）
  bool _volumeKeyTurn = false; // 音量键翻页
  bool _inkScreenMode = false; // 墨水屏模式（漫画黑白 + 柔和浅灰底）
  int _pomodoroLoopCount = defaultPomodoroLoopCount; // 番茄钟循环次数
  int _pomodoroRestMinutes = defaultPomodoroRestMinutes; // 番茄钟每轮休息分钟

  int get maxConcurrentChapters => _maxConcurrentChapters;
  int get maxConcurrentImages => _maxConcurrentImages;
  ReadingMode get readingMode => _readingMode;
  BookReadingMode get bookReadingMode => _bookReadingMode;
  String? get downloadSavePath => _downloadSavePath;
  bool get mergeChapterToEpub => _mergeChapterToEpub;
  bool get keepImagesAfterEpub => _keepImagesAfterEpub;
  int get mergeChaptersPerEpub => _mergeChaptersPerEpub;
  bool get trimWhitespace => _trimWhitespace;
  DefaultHomePage get defaultHomePage => _defaultHomePage;
  bool get useBuiltinAccount => _useBuiltinAccount;
  bool get checkUpdateOnStartup => _checkUpdateOnStartup;
  bool get isDarkMode => _themeFollowSystem
      ? (PlatformDispatcher.instance.platformBrightness == Brightness.dark)
      : _isDarkMode;
  bool get themeFollowSystem => _themeFollowSystem;
  String get themePreset => _themePreset;
  bool get backgroundAnimation => _backgroundAnimation;
  bool get frameRateReduced => _frameRateReduced;
  List<ThemePresetInfo> get customThemes => List.unmodifiable(_customThemes);

  /// 当前主题信息（内置或自定义），未知 id 兜底 jelly；供 UI 显示主题名。
  ThemePresetInfo get currentThemeInfo {
    for (final t in _customThemes) {
      if (t.id == _themePreset) return t;
    }
    return themePresets.firstWhere(
      (p) => p.id == _themePreset,
      orElse: () => themePresets.first,
    );
  }

  /// 当前生效的背景配置：内置预设恒为其自身动画（保持原有行为）；自定义主题
  /// 返回其 [ThemeBackground]；未知 id 回退纯色。渲染层据此决定画动画/图片/纯色。
  ThemeBackground get currentBackground {
    switch (_themePreset) {
      case 'jelly':
      case 'pink':
      case 'green':
      case 'ocean':
      case 'sunset':
      case 'sky':
        return ThemeBackground.animation(_themePreset);
      default:
        for (final t in _customThemes) {
          if (t.id == _themePreset) return t.background;
        }
        return const ThemeBackground.none();
    }
  }

  /// 按 id 解析调色板：先查自定义，再回退内置 fromPreset。
  JellyPalette _resolvePalette(String id) {
    for (final t in _customThemes) {
      if (t.id == id) return t.palette;
    }
    return JellyPalette.fromPreset(id);
  }

  int get preloadImageCount => _preloadImageCount;
  double get bookFontSize => _bookFontSize;
  double get bookLineHeight => _bookLineHeight;
  double get bookHorizontalPadding => _bookHorizontalPadding;
  double get bookVerticalPadding => _bookVerticalPadding;
  String? get bookFontFamily => _bookFontFamily;
  List<NavTab> get visibleNavTabs => List.unmodifiable(_visibleNavTabs);
  bool get navFloating => _navFloating;
  bool get pageTabsFollowNav => _pageTabsFollowNav;
  PageDefaultContent get pageDefaultContent => _pageDefaultContent;
  bool get reverseTap => _reverseTap;
  bool get doublePage => _doublePage;
  bool get showReaderHud => _showReaderHud;
  bool get volumeKeyTurn => _volumeKeyTurn;
  bool get inkScreenMode => _inkScreenMode;
  int get pomodoroLoopCount => _pomodoroLoopCount;
  int get pomodoroRestMinutes => _pomodoroRestMinutes;

  /// 收藏/书架/下载三页的有效内容 tab 顺序（受 pageTabsFollowNav + visibleNavTabs 影响）。
  /// 跟随开关关：[漫画, 图书]；开：取 visibleNavTabs 中的漫画/图书（按固定顺序）；
  /// 若两者都被隐藏，强制保留默认内容 tab，保证页面始终可用。
  List<NavTab> effectiveContentTabs() {
    if (!pageTabsFollowNav) return const [NavTab.manga, NavTab.book];
    final visible = _visibleNavTabs.toSet();
    final tabs = <NavTab>[];
    if (visible.contains(NavTab.manga)) tabs.add(NavTab.manga);
    if (visible.contains(NavTab.book)) tabs.add(NavTab.book);
    if (tabs.isEmpty) {
      tabs.add(
        pageDefaultContent == PageDefaultContent.manga
            ? NavTab.manga
            : NavTab.book,
      );
    }
    return tabs;
  }

  /// 三页默认 tab index：pageDefaultContent 在有效 tabs 中的位置，不可见则 0。
  int defaultContentTabIndex() {
    final tabs = effectiveContentTabs();
    final want = pageDefaultContent == PageDefaultContent.manga
        ? NavTab.manga
        : NavTab.book;
    final idx = tabs.indexOf(want);
    return idx >= 0 ? idx : 0;
  }

  /// 图书正文字体由阅读模式派生：仿真翻页用水墨楷体，普通翻页用系统默认。
  /// 切换模式时自动联动，无需独立持久化。
  String? get bookFontFamilyName =>
      _bookReadingMode == BookReadingMode.simulation ? 'inkReadingKai' : null;

  /// 初始化：从本地加载设置
  Future<void> init() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      _maxConcurrentChapters = _clamp(
        prefs.getInt(_chaptersKey) ?? defaultConcurrentChapters,
        minConcurrentChapters,
        maxConcurrentChaptersLimit,
      );
      _maxConcurrentImages = _clamp(
        prefs.getInt(_imagesKey) ?? defaultConcurrentImages,
        minConcurrentImages,
        maxConcurrentImagesLimit,
      );
      final modeIdx = prefs.getInt(_readingModeKey);
      if (modeIdx != null &&
          modeIdx >= 0 &&
          modeIdx < ReadingMode.values.length) {
        _readingMode = ReadingMode.values[modeIdx];
      }
      final brmIdx = prefs.getInt(_kBookReadingModeKey);
      if (brmIdx != null &&
          brmIdx >= 0 &&
          brmIdx < BookReadingMode.values.length) {
        _bookReadingMode = BookReadingMode.values[brmIdx];
      }
      _downloadSavePath = prefs.getString(_savePathKey);
      _mergeChapterToEpub = prefs.getBool(_mergeEpubKey) ?? true;
      _keepImagesAfterEpub = prefs.getBool(_keepImagesKey) ?? true;
      _trimWhitespace = prefs.getBool(_trimWhitespaceKey) ?? false;
      _mergeChaptersPerEpub =
          prefs
              .getInt(_mergeChaptersCountKey)
              ?.clamp(minMergeChaptersPerEpub, maxMergeChaptersPerEpub) ??
          1;
      // 默认首页：v1 枚举顺序为 漫画/图书/收藏/书架/我的，v2 将书架与收藏互换。
      // v1 按下标持久化，换序后需按下标还原旧 tab 再映射到新枚举，避免老用户默认首页错位。
      final navOrderVersion = prefs.getInt(_kNavOrderVersionKey) ?? 1;
      final homeIdx = prefs.getInt(_defaultHomeKey);
      if (navOrderVersion < 2) {
        const v1Order = <NavTab>[
          NavTab.manga,
          NavTab.book,
          NavTab.favorites,
          NavTab.bookshelf,
          NavTab.me,
        ];
        final migrated =
            (homeIdx != null && homeIdx >= 0 && homeIdx < v1Order.length)
            ? v1Order[homeIdx].toDefaultHomePage()
            : DefaultHomePage.manga;
        _defaultHomePage = migrated;
        await prefs.setInt(_defaultHomeKey, migrated.index);
        await prefs.setInt(_kNavOrderVersionKey, 2);
      } else {
        _defaultHomePage =
            (homeIdx != null &&
                homeIdx >= 0 &&
                homeIdx < DefaultHomePage.values.length)
            ? DefaultHomePage.values[homeIdx]
            : DefaultHomePage.manga;
      }
      _useBuiltinAccount = prefs.getBool(_kBuiltinAccountKey) ?? true;
      _checkUpdateOnStartup = prefs.getBool(_kCheckUpdateKey) ?? true;
      // 暗色模式：有记录用记录，否则首次跟随系统
      _isDarkMode =
          prefs.getBool(_kDarkModeKey) ??
          (PlatformDispatcher.instance.platformBrightness == Brightness.dark);
      // 主题跟随系统：默认开启；开启时 isDarkMode 取系统明暗，并实时响应系统切换
      _themeFollowSystem = prefs.getBool(_kThemeFollowSystemKey) ?? true;
      // 自定义主题：JSON 解析，坏条目跳过（韧性，不阻断启动）
      _customThemes = _loadCustomThemes(prefs.getString(_kCustomThemesKey));
      // 主题预设：默认 jelly；加载后立即应用到 JellyTheme（runApp 前，冷启动即生效）
      _themePreset = prefs.getString(_kThemePresetKey) ?? 'jelly';
      // 若存的主题已被删除，回退 jelly
      if (!_isKnownPreset(_themePreset)) _themePreset = 'jelly';
      JellyTheme.apply(_resolvePalette(_themePreset));
      _backgroundAnimation = prefs.getBool(_kBgAnimationKey) ?? true;
      _frameRateReduced = prefs.getBool(_kFrameRateReducedKey) ?? true;
      _preloadImageCount = _clamp(
        prefs.getInt(_preloadKey) ?? defaultPreloadImages,
        minPreloadImages,
        maxPreloadImages,
      );
      _pomodoroLoopCount = _clamp(
        prefs.getInt(_kPomodoroLoopCountKey) ?? defaultPomodoroLoopCount,
        minPomodoroLoopCount,
        maxPomodoroLoopCount,
      );
      _pomodoroRestMinutes = _clamp(
        prefs.getInt(_kPomodoroRestMinutesKey) ?? defaultPomodoroRestMinutes,
        minPomodoroRestMinutes,
        maxPomodoroRestMinutes,
      );
      _bookFontSize = _clampDouble(
        prefs.getDouble(_kBookFontSizeKey) ?? defaultBookFontSize,
        minBookFontSize,
        maxBookFontSize,
      );
      _bookLineHeight = _clampDouble(
        prefs.getDouble(_kBookLineHeightKey) ?? defaultBookLineHeight,
        minBookLineHeight,
        maxBookLineHeight,
      );
      _bookHorizontalPadding = _clampDouble(
        prefs.getDouble(_kBookHorizontalPaddingKey) ??
            defaultBookHorizontalPadding,
        minBookHorizontalPadding,
        maxBookHorizontalPadding,
      );
      _bookVerticalPadding = _clampDouble(
        prefs.getDouble(_kBookVerticalPaddingKey) ?? defaultBookVerticalPadding,
        minBookVerticalPadding,
        maxBookVerticalPadding,
      );
      // 图书正文字体偏好（null/空字符串均视为未设置 = 跟随阅读模式）。
      final savedFont = prefs.getString(_kBookFontFamilyKey);
      _bookFontFamily = (savedFont == null || savedFont.isEmpty)
          ? null
          : savedFont;
      // 导航栏悬浮开关
      _navFloating = prefs.getBool(_kNavFloatingKey) ?? true;
      // 当前漫画源
      _currentSourceId = prefs.getString(_currentSourceKey) ?? 'copymanga';
      // 禁用漫画源列表
      _disabledSourceIds = prefs.getStringList(_disabledSourceIdsKey) ?? [];
      // 漫画源仓库云端 URL
      _sourceRepoUrl = prefs.getString(_sourceRepoUrlKey) ?? '';
      // 导航栏可见 tab
      final visibleTabNames = prefs.getStringList(_kNavVisibleTabsKey);
      if (visibleTabNames != null && visibleTabNames.isNotEmpty) {
        final parsed = <NavTab>[];
        for (final name in visibleTabNames) {
          final tab = NavTab.values.where((t) => t.name == name).firstOrNull;
          if (tab != null) parsed.add(tab);
        }
        _visibleNavTabs = _sanitizeVisibleNavTabs(parsed);
      }
      // 收藏/书架/下载页 tab 跟随导航栏
      _pageTabsFollowNav = prefs.getBool(_kPageTabsFollowNavKey) ?? true;
      final pdcIdx = prefs.getInt(_kPageDefaultContentKey);
      if (pdcIdx != null &&
          pdcIdx >= 0 &&
          pdcIdx < PageDefaultContent.values.length) {
        _pageDefaultContent = PageDefaultContent.values[pdcIdx];
      }
      _reverseTap = prefs.getBool(_kReverseTapKey) ?? false;
      _doublePage = prefs.getBool(_kDoublePageKey) ?? false;
      _showReaderHud = prefs.getBool(_kShowReaderHudKey) ?? true;
      _volumeKeyTurn = prefs.getBool(_kVolumeKeyTurnKey) ?? false;
      _inkScreenMode = prefs.getBool(_kInkScreenModeKey) ?? false;
      // 若默认首页不在可见列表中，自动修正到第一个可见
      if (!_visibleNavTabs.any((t) => t == _defaultHomePage.toNavTab())) {
        _defaultHomePage = _visibleNavTabs.first.toDefaultHomePage();
      }
      _log(
        '设置加载: 同时下载量=$_maxConcurrentChapters, 分片并发=$_maxConcurrentImages, '
        '漫画阅读模式=$_readingMode, 图书阅读模式=$_bookReadingMode, 保存路径=${_downloadSavePath ?? "默认"}, '
        '合并EPUB=$_mergeChapterToEpub, 合并话数=$_mergeChaptersPerEpub, 保留图片=$_keepImagesAfterEpub, '
        '默认首页=$_defaultHomePage, 内置账号=$_useBuiltinAccount, 启动检查更新=$_checkUpdateOnStartup, 暗色模式=$_isDarkMode, 跟随系统=$_themeFollowSystem, 主题预设=$_themePreset, 预加载=$_preloadImageCount, '
        '图书排版: 字号=$_bookFontSize 行距=$_bookLineHeight 左右边距=$_bookHorizontalPadding 上下边距=$_bookVerticalPadding, '
        '翻页反转=$_reverseTap, 双页=$_doublePage, 信息栏=$_showReaderHud, 音量键翻页=$_volumeKeyTurn, 墨水屏=$_inkScreenMode',
      );
    } catch (e) {
      _log('加载设置失败: $e');
    }
    // 系统明暗变化时，若处于"跟随系统"则通知 UI 实时刷新（触发既有主题切换动画）
    PlatformDispatcher.instance.onPlatformBrightnessChanged = () {
      if (_themeFollowSystem) notifyListeners();
    };
    notifyListeners();
  }

  /// 设置同时下载量（自动 clamp）
  Future<void> setMaxConcurrentChapters(int value) async {
    final clamped = _clamp(
      value,
      minConcurrentChapters,
      maxConcurrentChaptersLimit,
    );
    if (_maxConcurrentChapters == clamped) return;
    _maxConcurrentChapters = clamped;
    notifyListeners();
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setInt(_chaptersKey, clamped);
    } catch (e) {
      _log('保存同时下载量失败: $e');
    }
  }

  /// 设置番茄钟循环次数（自动 clamp）
  Future<void> setPomodoroLoopCount(int value) async {
    final clamped = _clamp(value, minPomodoroLoopCount, maxPomodoroLoopCount);
    if (_pomodoroLoopCount == clamped) return;
    _pomodoroLoopCount = clamped;
    notifyListeners();
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setInt(_kPomodoroLoopCountKey, clamped);
    } catch (e) {
      _log('保存番茄钟循环次数失败: $e');
    }
  }

  /// 设置番茄钟每轮休息分钟（自动 clamp）
  Future<void> setPomodoroRestMinutes(int value) async {
    final clamped = _clamp(
      value,
      minPomodoroRestMinutes,
      maxPomodoroRestMinutes,
    );
    if (_pomodoroRestMinutes == clamped) return;
    _pomodoroRestMinutes = clamped;
    notifyListeners();
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setInt(_kPomodoroRestMinutesKey, clamped);
    } catch (e) {
      _log('保存番茄钟休息分钟失败: $e');
    }
  }

  /// 设置分片并发量（自动 clamp）
  Future<void> setMaxConcurrentImages(int value) async {
    final clamped = _clamp(
      value,
      minConcurrentImages,
      maxConcurrentImagesLimit,
    );
    if (_maxConcurrentImages == clamped) return;
    _maxConcurrentImages = clamped;
    notifyListeners();
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setInt(_imagesKey, clamped);
    } catch (e) {
      _log('保存分片并发量失败: $e');
    }
  }

  /// 设置阅读模式（翻页 / 拼页）
  Future<void> setReadingMode(ReadingMode mode) async {
    if (_readingMode == mode) return;
    _readingMode = mode;
    notifyListeners();
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setInt(_readingModeKey, mode.index);
    } catch (e) {
      _log('保存阅读模式失败: $e');
    }
  }

  /// 设置图书阅读模式（翻页 / 仿真 / 覆盖）
  Future<void> setBookReadingMode(BookReadingMode mode) async {
    if (_bookReadingMode == mode) return;
    _bookReadingMode = mode;
    notifyListeners();
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setInt(_kBookReadingModeKey, mode.index);
    } catch (e) {
      _log('保存图书阅读模式失败: $e');
    }
  }

  /// 设置下载保存位置（null/空 = 默认应用私有目录）
  Future<void> setDownloadSavePath(String? value) async {
    final v = (value != null && value.trim().isEmpty) ? null : value;
    if (_downloadSavePath == v) return;
    _downloadSavePath = v;
    notifyListeners();
    try {
      final prefs = await SharedPreferences.getInstance();
      if (v == null) {
        await prefs.remove(_savePathKey);
      } else {
        await prefs.setString(_savePathKey, v);
      }
    } catch (e) {
      _log('保存下载位置失败: $e');
    }
  }

  /// 设置：漫画下载时是否去白边
  Future<void> setTrimWhitespace(bool value) async {
    if (_trimWhitespace == value) return;
    _trimWhitespace = value;
    notifyListeners();
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(_trimWhitespaceKey, value);
    } catch (e) {
      _log('保存去白边开关失败: $e');
    }
  }

  /// 设置：漫画章节下载是否合并成 EPUB
  Future<void> setMergeChapterToEpub(bool value) async {
    if (_mergeChapterToEpub == value) return;
    _mergeChapterToEpub = value;
    notifyListeners();
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(_mergeEpubKey, value);
    } catch (e) {
      _log('保存合并EPUB开关失败: $e');
    }
  }

  /// 设置：合并 EPUB 后是否保留原始图片（用于 App 内离线阅读）
  Future<void> setKeepImagesAfterEpub(bool value) async {
    if (_keepImagesAfterEpub == value) return;
    _keepImagesAfterEpub = value;
    notifyListeners();
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(_keepImagesKey, value);
    } catch (e) {
      _log('保存保留图片开关失败: $e');
    }
  }

  /// 设置：每 N 话合并为一个 EPUB（1~20）
  Future<void> setMergeChaptersPerEpub(int value) async {
    final clamped = value.clamp(
      minMergeChaptersPerEpub,
      maxMergeChaptersPerEpub,
    );
    if (_mergeChaptersPerEpub == clamped) return;
    _mergeChaptersPerEpub = clamped;
    notifyListeners();
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setInt(_mergeChaptersCountKey, clamped);
    } catch (e) {
      _log('保存合并话数失败: $e');
    }
  }

  /// 设置启动默认首页
  Future<void> setDefaultHomePage(DefaultHomePage value) async {
    if (_defaultHomePage == value) return;
    _defaultHomePage = value;
    notifyListeners();
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setInt(_defaultHomeKey, value.index);
    } catch (e) {
      _log('保存默认首页失败: $e');
    }
  }

  /// 设置：图书下载未登录时是否使用内置账号（关闭则下载必须登录；搜索不受影响，未登录一律回退内置账号）
  Future<void> setUseBuiltinAccount(bool value) async {
    if (_useBuiltinAccount == value) return;
    _useBuiltinAccount = value;
    notifyListeners();
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(_kBuiltinAccountKey, value);
    } catch (e) {
      _log('保存内置账号开关失败: $e');
    }
  }

  /// 设置：启动时是否自动检查 app 新版本
  Future<void> setCheckUpdateOnStartup(bool value) async {
    if (_checkUpdateOnStartup == value) return;
    _checkUpdateOnStartup = value;
    notifyListeners();
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(_kCheckUpdateKey, value);
    } catch (e) {
      _log('保存启动检查更新开关失败: $e');
    }
  }

  /// 设置：暗色模式
  Future<void> setDarkMode(bool value) async {
    if (_isDarkMode == value) return;
    _isDarkMode = value;
    notifyListeners();
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(_kDarkModeKey, value);
    } catch (e) {
      _log('保存暗色模式失败: $e');
    }
  }

  /// 设置：主题背景动画开关
  Future<void> setBackgroundAnimation(bool value) async {
    if (_backgroundAnimation == value) return;
    _backgroundAnimation = value;
    notifyListeners();
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(_kBgAnimationKey, value);
    } catch (e) {
      _log('保存背景动画开关失败: $e');
    }
  }

  /// 设置：主题动画降帧省电
  Future<void> setFrameRateReduced(bool value) async {
    if (_frameRateReduced == value) return;
    _frameRateReduced = value;
    notifyListeners();
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(_kFrameRateReducedKey, value);
    } catch (e) {
      _log('保存降帧开关失败: $e');
    }
  }

  /// 设置：主题是否跟随系统明暗
  /// 关闭时把当前生效的暗色状态固化为手动选择，避免切到手动瞬间跳变。
  Future<void> setThemeFollowSystem(bool value) async {
    if (_themeFollowSystem == value) return;
    if (!value) {
      // 退出跟随系统前，用当前生效（可能来自系统）的状态初始化手动值
      _isDarkMode = isDarkMode;
    }
    _themeFollowSystem = value;
    notifyListeners();
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(_kThemeFollowSystemKey, value);
      if (!value) {
        await prefs.setBool(_kDarkModeKey, _isDarkMode);
      }
    } catch (e) {
      _log('保存主题跟随系统失败: $e');
    }
  }

  /// 设置：主题预设（内置 jelly/pink/green/ocean/sunset/sky，或 custom_* 自定义；
  /// 未知值兜底回 jelly）
  Future<void> setThemePreset(String value) async {
    final v = _isKnownPreset(value) ? value : 'jelly';
    if (_themePreset == v) return;
    _themePreset = v;
    JellyTheme.apply(_resolvePalette(v));
    notifyListeners();
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_kThemePresetKey, v);
    } catch (e) {
      _log('保存主题预设失败: $e');
    }
  }

  /// id 是否为已知主题（内置预设或已存自定义）。
  bool _isKnownPreset(String id) {
    if (id == 'jelly' ||
        id == 'pink' ||
        id == 'green' ||
        id == 'ocean' ||
        id == 'sunset' ||
        id == 'sky') {
      return true;
    }
    return _customThemes.any((t) => t.id == id);
  }

  /// 新增自定义主题：生成唯一 id，加入列表并持久化；返回新建信息（不自动选中）。
  ///
  /// [background] 默认纯色；图片背景会把源图复制到 app 持久目录，持久化副本路径
  /// （源图在相册/缓存可能被系统清除）。复制失败时该主题降级为纯色，不阻断保存。
  Future<ThemePresetInfo> addCustomTheme({
    required String name,
    required JellyPalette palette,
    ThemeBackground background = const ThemeBackground(),
  }) async {
    final trimmed = name.trim().isEmpty ? '自定义主题' : name.trim();
    final id =
        'custom_${DateTime.now().millisecondsSinceEpoch}_${_customThemes.length}';
    final installed = await _installBackgroundImage(id, _normalize(background));
    final info = ThemePresetInfo(id, trimmed, palette, background: installed);
    _customThemes = [..._customThemes, info];
    notifyListeners();
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_kCustomThemesKey, _encodeCustomThemes());
    } catch (e) {
      _log('保存自定义主题失败: $e');
    }
    return info;
  }

  /// 更新已有自定义主题（按 id）：name/palette/background 传非 null 才覆盖。
  /// 若更新的是当前选中主题，重新应用调色板（背景由 [currentBackground] 自动反映）。
  /// 图片背景按需复制新图/删除旧图（见 [_reconcileBackgroundImage]）。
  Future<void> updateCustomTheme(
    String id, {
    String? name,
    JellyPalette? palette,
    ThemeBackground? background,
  }) async {
    final idx = _customThemes.indexWhere((t) => t.id == id);
    if (idx < 0) return;
    final old = _customThemes[idx];
    final newName = (name == null || name.trim().isEmpty)
        ? old.name
        : name.trim();
    final newPalette = palette ?? old.palette;
    var newBg = old.background;
    if (background != null) {
      newBg = await _reconcileBackgroundImage(
        id,
        old.background,
        _normalize(background),
      );
    }
    final updated = ThemePresetInfo(id, newName, newPalette, background: newBg);
    final list = List<ThemePresetInfo>.of(_customThemes);
    list[idx] = updated;
    _customThemes = list;
    if (_themePreset == id) {
      JellyTheme.apply(newPalette); // 当前主题：重新应用调色板
    }
    notifyListeners();
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_kCustomThemesKey, _encodeCustomThemes());
    } catch (e) {
      _log('更新自定义主题失败: $e');
    }
  }

  /// 删除自定义主题；若删的正是当前选中，回退 jelly 并触发切换动画。
  Future<void> deleteCustomTheme(String id) async {
    ThemePresetInfo? target;
    for (final t in _customThemes) {
      if (t.id == id) {
        target = t;
        break;
      }
    }
    if (target == null) return;
    // 清理该主题的背景图片副本（best-effort，失败不阻断删除）
    if (target.background.type == ThemeBackgroundType.image &&
        target.background.imagePath != null) {
      await _deleteBackgroundImage(target.background.imagePath!);
    }
    _customThemes = _customThemes.where((t) => t.id != id).toList();
    final wasSelected = _themePreset == id;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_kCustomThemesKey, _encodeCustomThemes());
    } catch (e) {
      _log('删除自定义主题失败: $e');
    }
    if (wasSelected) {
      // 回退 jelly：直接改字段+应用，再走持久化（避免 setThemePreset 的相同 id 短路）
      _themePreset = 'jelly';
      JellyTheme.apply(const JellyPalette.jelly());
      try {
        final prefs = await SharedPreferences.getInstance();
        await prefs.setString(_kThemePresetKey, 'jelly');
      } catch (e) {
        _log('回退主题预设失败: $e');
      }
    }
    notifyListeners();
  }

  /// 自定义主题列表序列化为 JSON 字符串。
  String _encodeCustomThemes() {
    return jsonEncode(
      _customThemes
          .map(
            (t) => {
              'id': t.id,
              'name': t.name,
              'colors': t.palette.toMap(),
              'background': t.background.toMap(),
            },
          )
          .toList(),
    );
  }

  /// 从 JSON 字符串解析自定义主题列表；坏条目跳过。
  List<ThemePresetInfo> _loadCustomThemes(String? raw) {
    if (raw == null || raw.isEmpty) return [];
    try {
      final list = jsonDecode(raw);
      if (list is! List) return [];
      final result = <ThemePresetInfo>[];
      for (final item in list) {
        if (item is! Map) continue;
        final id = item['id'];
        final name = item['name'];
        final colors = item['colors'];
        if (id is! String || name is! String || colors is! Map) continue;
        try {
          final palette = JellyPalette.fromMap(
            Map<String, dynamic>.from(colors),
          );
          result.add(
            ThemePresetInfo(
              id,
              name,
              palette,
              background: ThemeBackground.fromMap(item['background']),
            ),
          );
        } catch (e) {
          _log('跳过损坏的自定义主题 $id: $e');
        }
      }
      return result;
    } catch (e) {
      _log('解析自定义主题失败: $e');
      return [];
    }
  }

  /// 图片背景副本目录：`<appDocs>/theme_bg/`（不存在则建）。
  Future<Directory> _themeBgDir() async {
    final appDir = await getApplicationDocumentsDirectory();
    final d = Directory('${appDir.path}/theme_bg');
    if (!d.existsSync()) await d.create(recursive: true);
    return d;
  }

  /// 把 [background] 的图片源文件复制到 app 持久目录，返回改写好 imagePath 的配置。
  /// 非 image 类型原样返回；复制失败降级纯色（不阻断保存）。
  Future<ThemeBackground> _installBackgroundImage(
    String id,
    ThemeBackground background,
  ) async {
    if (background.type != ThemeBackgroundType.image ||
        background.imagePath == null) {
      return background;
    }
    try {
      final src = File(background.imagePath!);
      if (!await src.exists()) {
        _log('背景图片源文件不存在，降级纯色: ${background.imagePath}');
        return const ThemeBackground.none();
      }
      final dir = await _themeBgDir();
      final dest = File('${dir.path}/bg_$id.${_pickImageExt(src.path)}');
      await src.copy(dest.path);
      return ThemeBackground.image(dest.path);
    } catch (e) {
      _log('复制背景图片失败，降级纯色: $e');
      return const ThemeBackground.none();
    }
  }

  /// 编辑时归一化：image 类型但无 imagePath（未选图）→ 视作纯色，避免存无效配置。
  ThemeBackground _normalize(ThemeBackground bg) =>
      (bg.type == ThemeBackgroundType.image && bg.imagePath == null)
      ? const ThemeBackground.none()
      : bg;

  /// 编辑主题时对图片背景做 reconciliation：
  /// - 切走图片（newBg 非 image）→ 删除旧副本；
  /// - 换新源图（路径不同且不在 theme_bg 内）→ 复制覆盖到 `bg_<id>.<ext>` 并删旧副本；
  /// - 同路径（仍是已安装副本）→ 原样返回。
  Future<ThemeBackground> _reconcileBackgroundImage(
    String id,
    ThemeBackground oldBg,
    ThemeBackground newBg,
  ) async {
    if (newBg.type != ThemeBackgroundType.image) {
      if (oldBg.type == ThemeBackgroundType.image && oldBg.imagePath != null) {
        await _deleteBackgroundImage(oldBg.imagePath!);
      }
      return newBg;
    }
    final newPath = newBg.imagePath!;
    if (newPath == oldBg.imagePath) return newBg; // 同图未换
    try {
      final src = File(newPath);
      if (!await src.exists()) {
        _log('编辑主题：新背景图源不存在，保留旧图');
        return oldBg.type == ThemeBackgroundType.image
            ? oldBg
            : const ThemeBackground.none();
      }
      final dir = await _themeBgDir();
      final dest = File('${dir.path}/bg_$id.${_pickImageExt(src.path)}');
      await src.copy(dest.path);
      if (oldBg.type == ThemeBackgroundType.image &&
          oldBg.imagePath != null &&
          oldBg.imagePath != dest.path) {
        await _deleteBackgroundImage(oldBg.imagePath!);
      }
      return ThemeBackground.image(dest.path);
    } catch (e) {
      _log('编辑主题：复制新背景图失败，保留旧图: $e');
      return oldBg.type == ThemeBackgroundType.image
          ? oldBg
          : const ThemeBackground.none();
    }
  }

  /// 删除背景图片副本（best-effort）。
  Future<void> _deleteBackgroundImage(String path) async {
    try {
      final f = File(path);
      if (await f.exists()) await f.delete();
    } catch (e) {
      _log('删除背景图片失败: $e');
    }
  }

  /// 取源路径图片扩展名（小写，非法/缺失回退 jpg），用于副本命名。
  String _pickImageExt(String path) {
    final dot = path.lastIndexOf('.');
    if (dot < 0 || dot == path.length - 1) return 'jpg';
    final ext = path.substring(dot + 1).toLowerCase();
    return RegExp(r'^[a-z0-9]{1,5}$').hasMatch(ext) ? ext : 'jpg';
  }

  /// 设置：在线阅读预加载图片数（自动 clamp 到 2~10）
  Future<void> setPreloadImageCount(int value) async {
    final clamped = _clamp(value, minPreloadImages, maxPreloadImages);
    if (_preloadImageCount == clamped) return;
    _preloadImageCount = clamped;
    notifyListeners();
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setInt(_preloadKey, clamped);
    } catch (e) {
      _log('保存预加载图片数失败: $e');
    }
  }

  /// 设置：图书字号（自动 clamp）
  Future<void> setBookFontSize(double value) async {
    final clamped = _clampDouble(value, minBookFontSize, maxBookFontSize);
    if (_bookFontSize == clamped) return;
    _bookFontSize = clamped;
    notifyListeners();
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setDouble(_kBookFontSizeKey, clamped);
    } catch (e) {
      _log('保存图书字号失败: $e');
    }
  }

  /// 设置：图书行距（自动 clamp）
  Future<void> setBookLineHeight(double value) async {
    final clamped = _clampDouble(value, minBookLineHeight, maxBookLineHeight);
    if (_bookLineHeight == clamped) return;
    _bookLineHeight = clamped;
    notifyListeners();
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setDouble(_kBookLineHeightKey, clamped);
    } catch (e) {
      _log('保存图书行距失败: $e');
    }
  }

  /// 设置：图书左右边距（自动 clamp）
  Future<void> setBookHorizontalPadding(double value) async {
    final clamped = _clampDouble(
      value,
      minBookHorizontalPadding,
      maxBookHorizontalPadding,
    );
    if (_bookHorizontalPadding == clamped) return;
    _bookHorizontalPadding = clamped;
    notifyListeners();
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setDouble(_kBookHorizontalPaddingKey, clamped);
    } catch (e) {
      _log('保存图书左右边距失败: $e');
    }
  }

  /// 设置：图书上下边距（自动 clamp）
  Future<void> setBookVerticalPadding(double value) async {
    final clamped = _clampDouble(
      value,
      minBookVerticalPadding,
      maxBookVerticalPadding,
    );
    if (_bookVerticalPadding == clamped) return;
    _bookVerticalPadding = clamped;
    notifyListeners();
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setDouble(_kBookVerticalPaddingKey, clamped);
    } catch (e) {
      _log('保存图书上下边距失败: $e');
    }
  }

  /// 设置：图书正文字体（value 同 [bookFontFamily] 约定）。
  Future<void> setBookFontFamily(String? value) async {
    final normalized = (value == null || value.isEmpty) ? null : value;
    if (_bookFontFamily == normalized) return;
    _bookFontFamily = normalized;
    notifyListeners();
    try {
      final prefs = await SharedPreferences.getInstance();
      if (normalized == null) {
        await prefs.remove(_kBookFontFamilyKey);
      } else {
        await prefs.setString(_kBookFontFamilyKey, normalized);
      }
    } catch (e) {
      _log('保存图书字体失败: $e');
    }
  }

  /// 设置导航栏可见 tab
  /// - "我的"始终显示
  /// - 漫画/图书/收藏/书架至少保留一个
  /// - 如果当前默认首页被隐藏，自动修正到第一个可见 tab
  Future<void> setVisibleNavTabs(List<NavTab> tabs) async {
    final sanitized = _sanitizeVisibleNavTabs(tabs);
    if (_listEquals(_visibleNavTabs, sanitized)) return;
    _visibleNavTabs = sanitized;

    // 若默认首页不在可见列表中，自动修正
    if (!_visibleNavTabs.any((t) => t == _defaultHomePage.toNavTab())) {
      _defaultHomePage = _visibleNavTabs.first.toDefaultHomePage();
    }

    notifyListeners();
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setStringList(
        _kNavVisibleTabsKey,
        sanitized.map((t) => t.name).toList(),
      );
      // 同步保存可能被修正的默认首页
      await prefs.setInt(_defaultHomeKey, _defaultHomePage.index);
    } catch (e) {
      _log('保存导航栏可见 tab 失败: $e');
    }
  }

  /// 设置：收藏/书架/下载页 tab 是否跟随导航栏 manga/book 可见性
  Future<void> setPageTabsFollowNav(bool value) async {
    if (_pageTabsFollowNav == value) return;
    _pageTabsFollowNav = value;
    notifyListeners();
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(_kPageTabsFollowNavKey, value);
    } catch (e) {
      _log('保存页面tab跟随导航栏失败: $e');
    }
  }

  /// 设置：收藏/书架/下载页默认显示内容（漫画/图书）
  Future<void> setPageDefaultContent(PageDefaultContent value) async {
    if (_pageDefaultContent == value) return;
    _pageDefaultContent = value;
    notifyListeners();
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setInt(_kPageDefaultContentKey, value.index);
    } catch (e) {
      _log('保存页面默认显示内容失败: $e');
    }
  }

  /// 设置：翻页按钮反转（左点下一页、右点上一页）
  Future<void> setReverseTap(bool value) async {
    if (_reverseTap == value) return;
    _reverseTap = value;
    notifyListeners();
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(_kReverseTapKey, value);
    } catch (e) {
      _log('保存翻页反转开关失败: $e');
    }
  }

  /// 设置：墨水屏模式开关（漫画黑白 + 柔和浅灰底）
  Future<void> setInkScreenMode(bool value) async {
    if (_inkScreenMode == value) return;
    _inkScreenMode = value;
    notifyListeners();
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(_kInkScreenModeKey, value);
    } catch (e) {
      _log('保存墨水屏模式开关失败: $e');
    }
  }

  /// 设置：双页模式（横屏左右并排两页，仅翻页模式生效）
  Future<void> setDoublePage(bool value) async {
    if (_doublePage == value) return;
    _doublePage = value;
    notifyListeners();
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(_kDoublePageKey, value);
    } catch (e) {
      _log('保存双页模式开关失败: $e');
    }
  }

  /// 设置：阅读信息栏（时间/页码/进度）
  Future<void> setShowReaderHud(bool value) async {
    if (_showReaderHud == value) return;
    _showReaderHud = value;
    notifyListeners();
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(_kShowReaderHudKey, value);
    } catch (e) {
      _log('保存阅读信息栏开关失败: $e');
    }
  }

  /// 设置：音量键翻页（阅读时按音量上/下键翻页）
  Future<void> setVolumeKeyTurn(bool value) async {
    if (_volumeKeyTurn == value) return;
    _volumeKeyTurn = value;
    notifyListeners();
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(_kVolumeKeyTurnKey, value);
    } catch (e) {
      _log('保存音量键翻页开关失败: $e');
    }
  }

  /// 校验可见 tab 列表：
  /// - 必须包含 me
  /// - 漫画/图书/收藏/书架至少一个
  /// - 保持原始顺序（按 NavTab.values 顺序排序）
  static List<NavTab> _sanitizeVisibleNavTabs(List<NavTab> tabs) {
    final set = tabs.toSet();
    // 必须有"我的"
    set.add(NavTab.me);
    // 漫画/图书/收藏/书架至少一个
    const contentTabs = [
      NavTab.manga,
      NavTab.book,
      NavTab.bookshelf,
      NavTab.favorites,
    ];
    final hasContent = contentTabs.any((t) => set.contains(t));
    if (!hasContent) {
      set.add(NavTab.manga); // 默认保留漫画
    }
    // 按固定顺序返回
    return NavTab.values.where((t) => set.contains(t)).toList();
  }

  /// 设置导航栏是否悬浮（胶囊型毛玻璃样式）
  Future<void> setNavFloating(bool value) async {
    if (_navFloating == value) return;
    _navFloating = value;
    notifyListeners();
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(_kNavFloatingKey, value);
    } catch (e) {
      _log('保存导航栏悬浮开关失败: $e');
    }
  }

  // === 漫画源 ===
  static const _currentSourceKey = 'current_source_id';
  String _currentSourceId = 'copymanga'; // 当前漫画源 id（默认拷贝漫画）
  String get currentSourceId => _currentSourceId;

  /// 设置当前漫画源 id
  Future<void> setCurrentSourceId(String value) async {
    if (_currentSourceId == value) return;
    _currentSourceId = value;
    notifyListeners();
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_currentSourceKey, value);
    } catch (e) {
      _log('保存当前漫画源失败: $e');
    }
  }

  static const _disabledSourceIdsKey = 'disabled_source_ids';
  List<String> _disabledSourceIds = []; // 禁用漫画源 id 列表（启用 = 不在此列表）
  List<String> get disabledSourceIds => _disabledSourceIds;

  /// 设置禁用漫画源 id 列表
  Future<void> setDisabledSourceIds(List<String> value) async {
    _disabledSourceIds = value;
    notifyListeners();
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setStringList(_disabledSourceIdsKey, value);
    } catch (e) {
      _log('保存禁用源列表失败: $e');
    }
  }

  static const _sourceRepoUrlKey = 'source_repo_url';
  String _sourceRepoUrl = ''; // 漫画源仓库云端 URL（后续拉取用）
  String get sourceRepoUrl => _sourceRepoUrl;

  /// 设置漫画源仓库云端 URL
  Future<void> setSourceRepoUrl(String value) async {
    _sourceRepoUrl = value;
    notifyListeners();
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_sourceRepoUrlKey, value);
    } catch (e) {
      _log('保存漫画源仓库URL失败: $e');
    }
  }

  static bool _listEquals<T>(List<T> a, List<T> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  static int _clamp(int v, int min, int max) =>
      v < min ? min : (v > max ? max : v);

  static double _clampDouble(double v, double min, double max) =>
      v < min ? min : (v > max ? max : v);

  /// 下载根目录：自定义保存位置优先（不存在则创建），否则回退应用私有目录下的 Cmbok。
  /// 漫画/图书下载服务共用，两者在该根下分 Comics / Books 子目录。
  static Future<Directory> downloadBaseDir() async {
    final custom = SettingsService().downloadSavePath;
    if (custom != null && custom.isNotEmpty) {
      try {
        final d = Directory(custom);
        if (!await d.exists()) {
          await d.create(recursive: true);
        }
        return d;
      } catch (e) {
        // 自定义目录不可用（权限被拒 / SD 卡未挂载等），回退默认，避免下载崩溃
        _log('自定义保存目录不可用，回退默认: $e');
      }
    }
    final doc = await getApplicationDocumentsDirectory();
    return Directory('${doc.path}/${AppConstants.downloadDir}');
  }
}
