import 'dart:convert';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import '../models/comic.dart';
import '../source/adapter.dart';
import '../source/source_manager.dart';
import '../services/download_service.dart';
import '../models/bookshelf.dart';
import '../services/bookshelf_service.dart';
import '../services/favorites_service.dart';
import '../services/reading_progress_service.dart';
import '../theme/jelly_theme.dart';
import '../widgets/download_chapter_sheet.dart';
import '../widgets/jelly_bookshelf_dialog.dart';
import '../widgets/jelly_score_badge.dart';
import '../widgets/theme_background_animation.dart';
import 'reader_page.dart';

/// 日志工具
void _log(String message) {
  if (kDebugMode) {
    debugPrint('[ComicDetail] $message');
  }
}

/// 漫画详情页面
class ComicDetailPage extends StatefulWidget {
  final Comic comic;

  /// 封面 Hero 动画 tag（与来源页卡片一致；为空则不启用过渡动画）
  final String? heroTag;

  const ComicDetailPage({super.key, required this.comic, this.heroTag});

  @override
  State<ComicDetailPage> createState() => _ComicDetailPageState();
}

class _ComicDetailPageState extends State<ComicDetailPage> {
  final ScrollController _scrollController = ScrollController();

  late Comic _comic;
  List<ChapterGroup> _groups = [];
  bool _isLoading = true;
  String? _error;

  int _selectedGroupIndex = 0;
  bool _showAllChapters = false; // 当前分组是否展开全部章节
  bool _descExpanded = false; // 简介是否展开
  bool _showBackToTop = false; // 是否显示返回顶部按钮

  /// 章节默认显示条数
  static const int _defaultVisibleChapters = 20;

  /// 触发返回顶部按钮的滚动阈值
  static const double _backToTopThreshold = 300;

  @override
  void initState() {
    super.initState();
    // 不从卡片带入状态/标签/简介，这些由详情页加载
    _comic = Comic(
      id: widget.comic.id,
      title: widget.comic.title,
      cover: widget.comic.cover,
      author: widget.comic.author,
      alias: widget.comic.alias,
      rating: widget.comic.rating,
      popular: widget.comic.popular,
      pathWord: widget.comic.pathWord,
      totalChapters: widget.comic.totalChapters,
      updateTime: widget.comic.updateTime,
      sourceId: widget.comic.sourceId,
    );
    _scrollController.addListener(_onScroll);
    DownloadService().addListener(_onDownloadChanged);
    ReadingProgressService().addListener(_onProgressChanged);
    _loadData();
  }

  @override
  void dispose() {
    _scrollController.removeListener(_onScroll);
    _scrollController.dispose();
    DownloadService().removeListener(_onDownloadChanged);
    ReadingProgressService().removeListener(_onProgressChanged);
    super.dispose();
  }

  /// 下载状态变化时刷新（更新章节已下载标记）
  void _onDownloadChanged() {
    if (mounted) setState(() {});
  }

  /// 阅读进度变化时刷新（更新“上次读到”章节的书签标识）
  void _onProgressChanged() {
    if (mounted) setState(() {});
  }

  void _onScroll() {
    if (!_scrollController.hasClients) return;
    final show = _scrollController.position.pixels > _backToTopThreshold;
    if (show != _showBackToTop) {
      setState(() => _showBackToTop = show);
    }
  }

  void _scrollToTop() {
    if (_scrollController.hasClients) {
      _scrollController.animateTo(
        0,
        duration: const Duration(milliseconds: 400),
        curve: Curves.easeOutCubic,
      );
    }
  }

  Future<void> _loadData() async {
    setState(() {
      _isLoading = true;
      _error = null;
    });

    try {
      // 一次请求同时加载详情与章节（避免对 comic2 重复请求触发风控）
      // 优先用漫画自身所属源（书架含多源漫画，当前选中源未必匹配）；
      // 旧数据无 sourceId 时兜底当前源
      final source = (_comic.sourceId != null && _comic.sourceId!.isNotEmpty)
          ? (SourceManager().getSource(_comic.sourceId!) ??
                SourceManager().current)
          : SourceManager().current;
      final details = await source.getMangaDetailsAndChapters(
        comicToCManga(_comic, source.id),
      );
      final result = (
        comic: cmangaToComic(details.manga),
        groups: cchaptersToGroups(details.chapters),
      );
      final detail = result.comic;
      final groups = result.groups;
      _log(
        '详情加载完成: status=${detail.status}, tags=${detail.tags}, '
        'description长度=${detail.description?.length ?? 0}, '
        'author=${detail.author}, totalChapters=${detail.totalChapters}',
      );
      _log('章节加载完成: ${groups.length} 个分组');
      if (!mounted) return; // 连续返回时页面可能已销毁，丢弃结果

      setState(() {
        _comic = _comic.copyWith(
          description: detail.description,
          status: detail.status,
          totalChapters: detail.totalChapters,
          author: detail.author,
          alias: detail.alias,
          tags: detail.tags,
          rating: detail.rating,
          popular: detail.popular,
          updateTime: detail.updateTime,
          sourceId: detail.sourceId ?? source.id,
        );
        // 章节按源站原始 order 排序，方向由源决定，统一「第1话在前」；
        // 与下载管理页/离线阅读器顺序保持一致，避免阅读与下载顺序对不上
        for (final g in groups) {
          g.chapters.sort(
            (a, b) =>
                chapterCompare(a.order, b.order, source.chapterOrderDescending),
          );
        }
        _groups = groups;
        _selectedGroupIndex = 0;
        _showAllChapters = false;
      });
      // 回填书架快照：用所有分组章节之和作为 totalChapters（与下载范围一致），
      // 供书架判断下载完整度与显示。与收藏解耦，直接写各书架 meta。
      // 同时更新 _comic：detail 接口的 totalChapters 常缺失，改用分组之和，
      // 使后续下载面板携带可靠的 totalChapters 写入下载快照。
      _comic = _comic.copyWith(totalChapters: _totalChapters);
      await BookshelfService().updateItemMeta(
        _comic.pathWord,
        BookshelfItemType.comic,
        jsonEncode(_comic.toJson()),
      );
    } catch (e) {
      _log('加载失败: $e');
      if (!mounted) return; // 页面已销毁，不更新 UI
      setState(() {
        _error = e.toString();
      });
    } finally {
      if (mounted) {
        setState(() {
          _isLoading = false;
        });
      }
    }
  }

  void _onChapterTap(ComicChapter chapter) {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (context) =>
            ReaderPage(comic: _comic, chapter: chapter, groups: _groups),
      ),
    );
  }

  /// 续读章节：从阅读进度取上次章节，在 _groups 中查找；无则 null（不显示续读按钮）
  ComicChapter? get _continueChapter {
    final rp = ReadingProgressService().getProgress(_comic.pathWord);
    if (rp == null) return null;
    for (final g in _groups) {
      for (final c in g.chapters) {
        if (c.id == rp.lastChapterId) return c;
      }
    }
    return null;
  }

  void _selectGroup(int index) {
    if (index == _selectedGroupIndex) return;
    setState(() {
      _selectedGroupIndex = index;
      _showAllChapters = false; // 切换分组重置展开状态
    });
  }

  /// 所有分组的章节总数
  int get _totalChapters =>
      _groups.fold<int>(0, (sum, g) => sum + g.chapters.length);

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      floatingActionButton: _buildBackToTopButton(),
      body: Stack(
        fit: StackFit.expand,
        children: [
          const RepaintBoundary(child: ThemeBackgroundAnimation()),
          CustomScrollView(
            controller: _scrollController,
            slivers: [
              _buildAppBar(),
              // 头部信息使用入参 comic 立即渲染，不阻塞于加载
              _buildHeader(),
              if (_isLoading)
                _buildChapterLoading()
              else if (_error != null)
                _buildChapterError()
              else ...[
                _buildLatestChapters(),
                _buildChapterSummary(),
                ..._buildChapterList(),
              ],
            ],
          ),
        ],
      ),
    );
  }

  SliverAppBar _buildAppBar() {
    return SliverAppBar(
      pinned: true,
      backgroundColor: Colors.transparent,
      surfaceTintColor: Colors.transparent,
      title: Text(
        _comic.title,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: const TextStyle(fontSize: 16),
      ),
    );
  }

  /// 封面（带 Hero 共享元素过渡）
  Widget _buildCover(bool isDark) {
    final cover = ClipRRect(
      borderRadius: BorderRadius.circular(12),
      child: SizedBox(
        width: 110,
        child: AspectRatio(
          aspectRatio: 3 / 4,
          child: CachedNetworkImage(
            imageUrl: _comic.cover,
            httpHeaders: coverHeaders(_comic.sourceId),
            fit: BoxFit.cover,
            placeholder: (c, u) => Container(
              color: isDark ? JellyTheme.cardDark : Colors.grey[200],
            ),
            errorWidget: (c, u, e) => Container(
              color: isDark ? JellyTheme.cardDark : Colors.grey[200],
              child: const Icon(
                Icons.broken_image,
                size: 40,
                color: Colors.grey,
              ),
            ),
          ),
        ),
      ),
    );
    final tag = widget.heroTag;
    return tag == null ? cover : Hero(tag: tag, child: cover);
  }

  /// 章节加载中（头部信息已用入参渲染，仅章节区显示加载动画）
  SliverFillRemaining _buildChapterLoading() {
    return SliverFillRemaining(
      hasScrollBody: false,
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            CircularProgressIndicator(color: JellyTheme.primary),
            SizedBox(height: 16),
            Text('加载中...', style: TextStyle(color: JellyTheme.textSecondary)),
          ],
        ),
      ),
    );
  }

  /// 章节加载失败
  SliverFillRemaining _buildChapterError() {
    return SliverFillRemaining(
      hasScrollBody: false,
      child: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Icon(Icons.error_outline, size: 48, color: Colors.red),
            const SizedBox(height: 16),
            Text('加载失败: $_error'),
            const SizedBox(height: 16),
            ElevatedButton(onPressed: _loadData, child: const Text('重试')),
          ],
        ),
      ),
    );
  }

  /// 顶部头部区：左封面 + 右元信息，下方简介
  SliverToBoxAdapter _buildHeader() {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final titleColor = isDark ? Colors.white : JellyTheme.textPrimaryLight;
    final secondaryColor = isDark ? Colors.white70 : JellyTheme.textSecondary;

    return SliverToBoxAdapter(
      child: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // 封面（Hero 共享元素过渡）
                _buildCover(isDark),
                const SizedBox(width: 14),
                // 元信息
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        _comic.title,
                        style: TextStyle(
                          fontSize: 20,
                          fontWeight: FontWeight.bold,
                          color: titleColor,
                        ),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                      if (_comic.author != null &&
                          _comic.author!.isNotEmpty) ...[
                        const SizedBox(height: 8),
                        Row(
                          children: [
                            Icon(
                              Icons.person_outline,
                              size: 15,
                              color: secondaryColor,
                            ),
                            const SizedBox(width: 4),
                            Expanded(
                              child: Text(
                                _comic.author!,
                                style: TextStyle(
                                  fontSize: 13,
                                  color: secondaryColor,
                                ),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                          ],
                        ),
                      ],
                      if (_comic.status != null &&
                          _comic.status!.isNotEmpty) ...[
                        const SizedBox(height: 8),
                        _buildStatusChip(_comic.status!, isDark),
                      ],
                      if (comicHasScore(_comic)) ...[
                        const SizedBox(height: 8),
                        JellyScoreBadge(comic: _comic, isDark: isDark),
                      ],
                      if (_comic.tags != null && _comic.tags!.isNotEmpty) ...[
                        const SizedBox(height: 8),
                        Wrap(
                          spacing: 6,
                          runSpacing: 6,
                          children: _comic.tags!
                              .take(4)
                              .map((t) => _buildTagChip(t, isDark))
                              .toList(),
                        ),
                      ],
                    ],
                  ),
                ),
              ],
            ),
            // 收藏 / 下载 胶囊按钮（简介上方靠右，避免在元信息窄列中溢出）
            const SizedBox(height: 12),
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                _buildFavoriteCapsule(),
                const SizedBox(width: 8),
                _buildBookshelfCapsule(),
                const SizedBox(width: 8),
                _buildCapsuleButton(
                  icon: Icons.download_for_offline,
                  label: '下载',
                  onTap: _openDownloadSheet,
                ),
              ],
            ),
            // 简介（漫画详情）
            if (_comic.description != null &&
                _comic.description!.isNotEmpty) ...[
              const SizedBox(height: 16),
              _buildSynopsis(titleColor, secondaryColor),
            ],
          ],
        ),
      ),
    );
  }

  /// 胶囊按钮（左图标 + 右文字）
  Widget _buildCapsuleButton({
    required IconData icon,
    required String label,
    required VoidCallback onTap,
    Color? color,
  }) {
    color ??= JellyTheme.primary;
    return Material(
      color: color,
      borderRadius: BorderRadius.circular(20),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 15, color: Colors.white),
              const SizedBox(width: 4),
              Text(
                label,
                style: const TextStyle(
                  fontSize: 12,
                  color: Colors.white,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// 续读胶囊按钮：跳到上次阅读章节（章节统计行右侧，有阅读进度时显示）
  Widget _buildContinueCapsule() {
    return _buildCapsuleButton(
      icon: Icons.play_arrow_rounded,
      label: '续读',
      onTap: () {
        final rp = ReadingProgressService().getProgress(_comic.pathWord);
        final chapter = _continueChapter;
        if (rp == null || chapter == null) return;
        Navigator.push(
          context,
          MaterialPageRoute(
            builder: (_) => ReaderPage(
              comic: _comic,
              chapter: chapter,
              groups: _groups,
              initialPage: rp.lastPageIndex,
            ),
          ),
        );
      },
    );
  }

  /// 收藏胶囊按钮（跟随收藏状态切换图标/文案/颜色）
  Widget _buildFavoriteCapsule() {
    return ListenableBuilder(
      listenable: FavoritesService(),
      builder: (context, _) {
        final fav = FavoritesService().isFavorite(_comic.id);
        return _buildCapsuleButton(
          icon: fav ? Icons.favorite : Icons.favorite_border,
          label: fav ? '已收藏' : '收藏',
          color: fav ? const Color(0xFFFF8B94) : JellyTheme.primary,
          onTap: () {
            FavoritesService().toggle(_comic);
            ScaffoldMessenger.of(context)
              ..hideCurrentSnackBar()
              ..showSnackBar(
                SnackBar(
                  content: Text(fav ? '已取消收藏' : '已收藏'),
                  duration: const Duration(seconds: 2),
                  behavior: SnackBarBehavior.floating,
                ),
              );
          },
        );
      },
    );
  }

  /// 加入书架胶囊按钮
  Widget _buildBookshelfCapsule() {
    return ListenableBuilder(
      listenable: BookshelfService(),
      builder: (context, _) {
        final inShelf = BookshelfService()
            .getBookshelvesForItem(_comic.pathWord, BookshelfItemType.comic)
            .isNotEmpty;
        return _buildCapsuleButton(
          icon: inShelf
              ? Icons.library_books_rounded
              : Icons.library_add_rounded,
          label: inShelf ? '已加书架' : '书架',
          color: inShelf ? const Color(0xFF7C8CFF) : JellyTheme.primary,
          onTap: () async {
            final hasReadingProgress =
                ReadingProgressService().getProgress(_comic.pathWord) != null;
            final result = await showBookshelfDialog(
              context,
              itemId: _comic.pathWord,
              type: BookshelfItemType.comic,
              title: '加入书架',
              meta: jsonEncode(_comic.toJson()),
              disabledShelfIds: hasReadingProgress
                  ? null
                  : {BookshelfService.presetReading},
            );
            if (result != null && mounted) {
              ScaffoldMessenger.of(context)
                ..hideCurrentSnackBar()
                ..showSnackBar(
                  SnackBar(
                    content: Text(
                      result.isEmpty ? '已从所有书架移除' : '已加入 ${result.length} 个书架',
                    ),
                    duration: const Duration(seconds: 2),
                    behavior: SnackBarBehavior.floating,
                  ),
                );
            }
          },
        );
      },
    );
  }

  /// 打开下载章节选择弹窗（当前分组）
  void _openDownloadSheet() {
    if (_groups.isEmpty) return;
    final group = _groups[_selectedGroupIndex.clamp(0, _groups.length - 1)];
    if (group.chapters.isEmpty) return;
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => DownloadChapterSheet(
        comic: _comic,
        chapters: group.chapters,
        groupName: group.name,
      ),
    );
  }

  Widget _buildStatusChip(String status, bool isDark) {
    final ongoing =
        status.contains('连载') || status.toLowerCase().contains('ongoing');
    final bg = ongoing
        ? JellyTheme.success
        : (isDark
              ? Colors.white.withValues(alpha: 0.12)
              : Colors.black.withValues(alpha: 0.06));
    final fg = ongoing
        ? Colors.white
        : (isDark ? Colors.white70 : JellyTheme.textSecondary);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Text(
        status,
        style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: fg),
      ),
    );
  }

  Widget _buildTagChip(String tag, bool isDark) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: isDark
            ? Colors.white.withValues(alpha: 0.08)
            : JellyTheme.primary.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Text(
        tag,
        style: TextStyle(
          fontSize: 11,
          color: isDark ? Colors.white70 : JellyTheme.primary,
        ),
      ),
    );
  }

  Widget _buildSynopsis(Color titleColor, Color secondaryColor) {
    final desc = _comic.description!;
    // 简介较长时提供展开/收起
    final likelyLong = desc.length > 60 || desc.contains('\n');
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          '简介',
          style: TextStyle(
            fontSize: 14,
            fontWeight: FontWeight.w700,
            color: titleColor,
          ),
        ),
        const SizedBox(height: 6),
        Text(
          desc,
          maxLines: _descExpanded ? null : 3,
          overflow: _descExpanded ? TextOverflow.clip : TextOverflow.ellipsis,
          style: TextStyle(fontSize: 13, height: 1.5, color: secondaryColor),
        ),
        if (likelyLong)
          Align(
            alignment: Alignment.centerRight,
            child: TextButton(
              onPressed: () => setState(() => _descExpanded = !_descExpanded),
              style: TextButton.styleFrom(
                minimumSize: const Size(0, 28),
                padding: const EdgeInsets.symmetric(horizontal: 8),
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              ),
              child: Text(
                _descExpanded ? '收起' : '展开',
                style: const TextStyle(fontSize: 12),
              ),
            ),
          ),
      ],
    );
  }

  /// 章节数统计：共多少话（按分组统计）
  /// 最新章节区（简介与章节之间）：最新10话横向卡片，点击在线阅读。
  /// 仅当当前分组章节 > 10 时显示；不参与下载选章（下载走 DownloadChapterSheet 完整列表）。
  SliverToBoxAdapter _buildLatestChapters() {
    if (_groups.isEmpty) {
      return const SliverToBoxAdapter(child: SizedBox.shrink());
    }
    final group = _groups[_selectedGroupIndex.clamp(0, _groups.length - 1)];
    final chapters = group.chapters;
    if (chapters.length <= 10) {
      return const SliverToBoxAdapter(child: SizedBox.shrink());
    }
    // 主列表已「第1话在前」，末尾即最新；取末尾10个反转为「最新在前」
    final latest = chapters.sublist(chapters.length - 10).reversed.toList();
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final titleColor = isDark ? Colors.white : JellyTheme.textPrimaryLight;
    final lastReadId = ReadingProgressService()
        .getProgress(_comic.pathWord)
        ?.lastChapterId;

    return SliverToBoxAdapter(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Text(
                '最新章节',
                style: TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.bold,
                  color: titleColor,
                ),
              ),
            ),
            SizedBox(
              height: 44,
              child: ListView.separated(
                scrollDirection: Axis.horizontal,
                itemCount: latest.length,
                separatorBuilder: (_, _) => const SizedBox(width: 8),
                itemBuilder: (context, index) {
                  final chapter = latest[index];
                  final downloaded = DownloadService().isChapterDownloaded(
                    _comic.pathWord,
                    chapter.id,
                  );
                  final isLastRead = lastReadId == chapter.id;
                  return Stack(
                    clipBehavior: Clip.none,
                    children: [
                      OutlinedButton(
                        onPressed: () => _onChapterTap(chapter),
                        style: OutlinedButton.styleFrom(
                          padding: const EdgeInsets.symmetric(horizontal: 10),
                          minimumSize: const Size(0, 36),
                          side: BorderSide(
                            color: isDark ? Colors.white70 : Colors.black38,
                          ),
                        ),
                        child: Text(
                          chapter.title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(fontSize: 11),
                        ),
                      ),
                      if (isLastRead)
                        Positioned(
                          left: 2,
                          top: 2,
                          child: Icon(
                            Icons.bookmark_rounded,
                            size: 12,
                            color: JellyTheme.blue,
                          ),
                        ),
                      if (downloaded)
                        Positioned(
                          right: 2,
                          top: 2,
                          child: Icon(
                            Icons.check_circle,
                            size: 12,
                            color: JellyTheme.success,
                          ),
                        ),
                    ],
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }

  SliverToBoxAdapter _buildChapterSummary() {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final titleColor = isDark ? Colors.white : JellyTheme.textPrimaryLight;
    return SliverToBoxAdapter(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            Text(
              '章节',
              style: TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.bold,
                color: titleColor,
              ),
            ),
            const SizedBox(width: 8),
            Text(
              '共 $_totalChapters 话',
              style: TextStyle(fontSize: 13, color: JellyTheme.textSecondary),
            ),
            if (_continueChapter != null) ...[
              const SizedBox(width: 12),
              _buildContinueCapsule(),
            ],
          ],
        ),
      ),
    );
  }

  /// 分组切换 + 章节列表
  List<Widget> _buildChapterList() {
    final slivers = <Widget>[];
    if (_groups.isEmpty) return slivers;

    // 分组选择器（有分组即显示，单分组时作为当前分组指示）
    if (_groups.isNotEmpty) {
      slivers.add(_buildGroupSelector());
    }

    final index = _selectedGroupIndex.clamp(0, _groups.length - 1);
    final group = _groups[index];
    final chapters = group.chapters;
    final lastReadId = ReadingProgressService()
        .getProgress(_comic.pathWord)
        ?.lastChapterId;
    final visibleCount = _showAllChapters
        ? chapters.length
        : chapters.length.clamp(0, _defaultVisibleChapters);
    final hasMore = chapters.length > _defaultVisibleChapters;

    slivers.add(
      SliverPadding(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
        sliver: SliverGrid(
          gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
            maxCrossAxisExtent: 100,
            childAspectRatio: 2.5,
            crossAxisSpacing: 8,
            mainAxisSpacing: 8,
          ),
          delegate: SliverChildBuilderDelegate((context, index) {
            final chapter = chapters[index];
            final isDark = Theme.of(context).brightness == Brightness.dark;
            final downloaded = DownloadService().isChapterDownloaded(
              _comic.pathWord,
              chapter.id,
            );
            final isLastRead = lastReadId == chapter.id;
            return Stack(
              fit: StackFit.expand,
              children: [
                OutlinedButton(
                  onPressed: () => _onChapterTap(chapter),
                  style: OutlinedButton.styleFrom(
                    padding: const EdgeInsets.symmetric(horizontal: 4),
                    side: BorderSide(
                      color: isDark ? Colors.white70 : Colors.black38,
                    ),
                  ),
                  child: Text(
                    chapter.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 11),
                  ),
                ),
                if (isLastRead)
                  Positioned(
                    left: 4,
                    top: 4,
                    child: Icon(
                      Icons.bookmark_rounded,
                      size: 14,
                      color: JellyTheme.blue,
                    ),
                  ),
                if (downloaded)
                  Positioned(
                    right: 4,
                    top: 4,
                    child: Icon(
                      Icons.check_circle,
                      size: 14,
                      color: JellyTheme.success,
                    ),
                  ),
              ],
            );
          }, childCount: visibleCount),
        ),
      ),
    );

    // 显示全部 / 收起
    if (hasMore) {
      slivers.add(
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 16),
            child: Center(
              child: TextButton.icon(
                onPressed: () =>
                    setState(() => _showAllChapters = !_showAllChapters),
                icon: Icon(
                  _showAllChapters
                      ? Icons.expand_less_rounded
                      : Icons.expand_more_rounded,
                  size: 18,
                ),
                label: Text(
                  _showAllChapters ? '收起' : '显示全部（共 ${chapters.length} 话）',
                ),
              ),
            ),
          ),
        ),
      );
    } else {
      slivers.add(const SliverToBoxAdapter(child: SizedBox(height: 16)));
    }

    return slivers;
  }

  /// 横向可滚动的分组选择器
  SliverToBoxAdapter _buildGroupSelector() {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return SliverToBoxAdapter(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
        child: SizedBox(
          height: 38,
          child: ListView.separated(
            scrollDirection: Axis.horizontal,
            itemCount: _groups.length,
            separatorBuilder: (_, _) => const SizedBox(width: 8),
            itemBuilder: (context, index) {
              final g = _groups[index];
              final selected = index == _selectedGroupIndex;
              return GestureDetector(
                onTap: () => _selectGroup(index),
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 14),
                  decoration: BoxDecoration(
                    color: selected
                        ? JellyTheme.primary
                        : (isDark
                              ? Colors.white.withValues(alpha: 0.06)
                              : Colors.white),
                    borderRadius: BorderRadius.circular(19),
                    border: Border.all(
                      color: selected
                          ? JellyTheme.primary
                          : (isDark ? Colors.white24 : Colors.black12),
                    ),
                  ),
                  alignment: Alignment.center,
                  child: Text(
                    '${g.name} (${g.chapters.length})',
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
                      color: selected
                          ? Colors.white
                          : (isDark
                                ? Colors.white70
                                : JellyTheme.textSecondary),
                    ),
                  ),
                ),
              );
            },
          ),
        ),
      ),
    );
  }

  /// 悬浮返回顶部按钮（带出现/消失动画，同搜索页）
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
