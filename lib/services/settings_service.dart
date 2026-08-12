import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../utils/constants.dart';

/// 日志工具
void _log(String message) {
  if (kDebugMode) {
    debugPrint('[Settings] $message');
  }
}

/// 漫画阅读模式：左右翻页（横向逐页）/ 消散（当前页淡出、下一页淡入）/ 拼页（上下连续滚动）
enum ReadingMode { pageTurn, continuous, dissolve }

/// 图书阅读模式：翻页 / 仿真翻页（卷曲） / 覆盖（新页滑入覆盖当前页）
enum BookReadingMode { pageTurn, simulation, cover }

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
  static const _defaultHomeKey = 'default_home_page';
  static const _kBuiltinAccountKey = 'use_builtin_account';
  static const _kDarkModeKey = 'dark_mode';
  static const _kThemeFollowSystemKey = 'theme_follow_system';
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
  DefaultHomePage _defaultHomePage = DefaultHomePage.manga;
  bool _useBuiltinAccount = true; // 图书下载未登录时是否回退内置账号（搜索一律回退内置账号）
  bool _checkUpdateOnStartup = true; // 启动时自动检查 app 新版本
  bool _isDarkMode = false; // 暗色模式（首次跟随系统，之后保留用户选择）
  bool _themeFollowSystem = true; // 主题跟随系统明暗；关闭后用上面的手动选择
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
  int _pomodoroLoopCount = defaultPomodoroLoopCount; // 番茄钟循环次数
  int _pomodoroRestMinutes = defaultPomodoroRestMinutes; // 番茄钟每轮休息分钟

  int get maxConcurrentChapters => _maxConcurrentChapters;
  int get maxConcurrentImages => _maxConcurrentImages;
  ReadingMode get readingMode => _readingMode;
  BookReadingMode get bookReadingMode => _bookReadingMode;
  String? get downloadSavePath => _downloadSavePath;
  bool get mergeChapterToEpub => _mergeChapterToEpub;
  bool get keepImagesAfterEpub => _keepImagesAfterEpub;
  DefaultHomePage get defaultHomePage => _defaultHomePage;
  bool get useBuiltinAccount => _useBuiltinAccount;
  bool get checkUpdateOnStartup => _checkUpdateOnStartup;
  bool get isDarkMode => _themeFollowSystem
      ? (PlatformDispatcher.instance.platformBrightness == Brightness.dark)
      : _isDarkMode;
  bool get themeFollowSystem => _themeFollowSystem;
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
      // 若默认首页不在可见列表中，自动修正到第一个可见
      if (!_visibleNavTabs.any((t) => t == _defaultHomePage.toNavTab())) {
        _defaultHomePage = _visibleNavTabs.first.toDefaultHomePage();
      }
      _log(
        '设置加载: 同时下载量=$_maxConcurrentChapters, 分片并发=$_maxConcurrentImages, '
        '漫画阅读模式=$_readingMode, 图书阅读模式=$_bookReadingMode, 保存路径=${_downloadSavePath ?? "默认"}, '
        '合并EPUB=$_mergeChapterToEpub, 保留图片=$_keepImagesAfterEpub, '
        '默认首页=$_defaultHomePage, 内置账号=$_useBuiltinAccount, 启动检查更新=$_checkUpdateOnStartup, 暗色模式=$_isDarkMode, 跟随系统=$_themeFollowSystem, 预加载=$_preloadImageCount, '
        '图书排版: 字号=$_bookFontSize 行距=$_bookLineHeight 左右边距=$_bookHorizontalPadding 上下边距=$_bookVerticalPadding, '
        '翻页反转=$_reverseTap, 双页=$_doublePage, 信息栏=$_showReaderHud, 音量键翻页=$_volumeKeyTurn',
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
