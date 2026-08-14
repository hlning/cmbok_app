import 'dart:convert';

import 'package:flutter/material.dart';

import '../models/bookshelf.dart';
import '../models/comic.dart';
import '../services/book_download_service.dart';
import '../services/book_reading_progress_service.dart';
import '../services/bookshelf_service.dart';
import '../services/browse_history_service.dart';
import '../services/download_service.dart';
import '../services/favorites_service.dart';
import '../services/reading_progress_service.dart';
import '../services/remote_config_service.dart';
import '../services/settings_service.dart';
import '../services/update_service.dart';
import '../source/adapter.dart';
import '../source/source_manager.dart';
import '../theme/jelly_theme.dart';
import '../widgets/bookshelf_icon.dart';
import '../widgets/jelly_nav_bar.dart';
import '../widgets/notification_popup.dart';
import '../widgets/theme_background.dart';
import '../widgets/update_dialog.dart';
import 'book_reader_page.dart';
import 'book_search_page.dart';
import 'bookshelf_page.dart';
import 'favorites_page.dart';
import 'me_page.dart';
import 'reader_page.dart';
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

  /// 底部导航栏长按回调：漫画 tab 续读最近漫画，图书 tab 续读最近图书
  void _onNavLongPress(int index) {
    final visible = SettingsService().visibleNavTabs;
    if (index < 0 || index >= visible.length) return;
    final tab = visible[index];
    switch (tab) {
      case NavTab.manga:
        _resumeLastComic();
        break;
      case NavTab.book:
        _resumeLastBook();
        break;
      case NavTab.bookshelf:
      case NavTab.favorites:
      case NavTab.me:
        // 其他 tab 暂无长按动作
        break;
    }
  }

  /// 续读最近阅读的漫画
  Future<void> _resumeLastComic() async {
    final recent = ReadingProgressService().getMostRecent();
    if (recent == null) {
      _showToast('暂无阅读记录');
      return;
    }
    final pathWord = recent.key;

    // 按优先级从本地查找 Comic 对象：书架 → 浏览历史 → 收藏
    Comic? comic = _findComicInShelf(pathWord);
    comic ??= _findComicInBrowseHistory(pathWord);
    comic ??= _findComicInFavorites(pathWord);

    if (comic == null) {
      _showToast('暂无阅读记录');
      return;
    }

    if (!mounted) return;
    await _openComicReader(comic);
  }

  /// 从书架 meta 中查找漫画
  Comic? _findComicInShelf(String pathWord) {
    final meta = BookshelfService().findItemMeta(
      pathWord,
      BookshelfItemType.comic,
    );
    if (meta == null) return null;
    try {
      return Comic.fromJson(jsonDecode(meta) as Map<String, dynamic>);
    } catch (_) {
      return null;
    }
  }

  /// 从浏览历史中查找漫画
  Comic? _findComicInBrowseHistory(String pathWord) {
    try {
      return BrowseHistoryService().comics.firstWhere(
            (c) => c.pathWord == pathWord || c.id == pathWord,
          );
    } catch (_) {
      return null;
    }
  }

  /// 从收藏中查找漫画
  Comic? _findComicInFavorites(String pathWord) {
    try {
      return FavoritesService().comics.firstWhere(
            (c) => c.pathWord == pathWord || c.id == pathWord,
          );
    } catch (_) {
      return null;
    }
  }

  /// 拉取漫画详情+章节后打开阅读器（续读章节或第一章）
  Future<void> _openComicReader(Comic comic) async {
    final rootNav = Navigator.of(context, rootNavigator: true);
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (_) => PopScope(
        canPop: false,
        child: Center(
          child: CircularProgressIndicator(color: JellyTheme.primary),
        ),
      ),
    );
    try {
      final source = (comic.sourceId != null && comic.sourceId!.isNotEmpty)
          ? (SourceManager().getSource(comic.sourceId!) ??
                SourceManager().current)
          : SourceManager().current;
      final details = await source.getMangaDetailsAndChapters(
        comicToCManga(comic, source.id),
      );
      final resultComic = cmangaToComic(details.manga);
      final groups = cchaptersToGroups(details.chapters);
      rootNav.pop();
      if (!mounted) return;

      // 章节按源站原始 order 排序，方向由源决定，统一「第1话在前」
      for (final g in groups) {
        g.chapters.sort(
          (a, b) =>
              chapterCompare(a.order, b.order, source.chapterOrderDescending),
        );
      }

      // 起始章节：续读章节；无记录则第一章
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
        if (!mounted) return;
        _showToast('暂无可读章节');
        return;
      }

      if (!mounted) return;
      await Navigator.push(
        context,
        MaterialPageRoute(
          builder: (_) => ReaderPage(
            comic: resultComic,
            chapter: start!,
            groups: groups,
            initialPage: initialPage,
          ),
        ),
      );
    } catch (e) {
      rootNav.pop();
      if (mounted) _showToast('打开失败：$e');
    }
  }

  /// 排序后首个非空分组的第一章
  ComicChapter? _firstChapter(List<ChapterGroup> groups) {
    for (final g in groups) {
      if (g.chapters.isNotEmpty) return g.chapters.first;
    }
    return null;
  }

  /// 续读最近阅读的图书
  Future<void> _resumeLastBook() async {
    final recent = BookReadingProgressService().getMostRecent();
    if (recent == null) {
      _showToast('暂无阅读记录');
      return;
    }
    final bookId = recent.key;
    final task = BookDownloadService().task(bookId);
    if (task == null || task.status != BookDownloadStatus.completed) {
      _showToast('该书尚未下载完成');
      return;
    }
    if (!mounted) return;
    await BookReaderPage.open(context, task);
  }

  void _showToast(String message) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text(message),
          duration: const Duration(seconds: 2),
          behavior: SnackBarBehavior.floating,
        ),
      );
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

        // 背景置于 Scaffold 外层全屏：键盘弹出时只压缩 Scaffold（前景避让），
        // 背景保持原尺寸被键盘自然遮挡，避免底部动画被顶到键盘上方、且随键盘逐帧重排卡顿
        return Stack(
          fit: StackFit.expand,
          children: [
            // 纯色底：纯色主题透出此色（背景全在外层不被键盘压缩；Scaffold 设透明避免遮挡）
            ColoredBox(color: Theme.of(context).scaffoldBackgroundColor),
            const RepaintBoundary(child: ThemeBackground()),
            Scaffold(
              backgroundColor: Colors.transparent,
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
                onLongPress: _onNavLongPress,
                items: navItems,
              ),
            ),
          ],
        );
      },
    );
  }
}
