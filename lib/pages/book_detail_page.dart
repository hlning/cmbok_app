import 'dart:convert';
import 'dart:math';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import '../models/book.dart';
import '../models/bookshelf.dart';
import '../services/book_download_service.dart';
import '../services/book_favorites_service.dart';
import '../services/book_reading_progress_service.dart';
import '../services/bookshelf_service.dart';
import '../services/zlibrary_service.dart';
import '../theme/jelly_theme.dart';
import '../widgets/jelly_bookshelf_dialog.dart';
import 'book_reader_page.dart';
import 'zlibrary_auth_page.dart';

/// 图书详情页面（参考漫画详情页 ComicDetailPage）
/// 封面独占顶部 -> 标题/作者/评分/元信息 -> 简介 -> 推荐图书 -> 收藏/下载胶囊。
/// 下载状态卡片仅在下载中/排队/暂停/失败时显示（不显示「已下载」与删除按钮）。
class BookDetailPage extends StatefulWidget {
  final Book book;
  final String? heroTag;

  /// 来自搜索页的结果列表，用于「推荐图书」随机取 5 本，避免额外请求。
  final List<Book>? searchResults;

  const BookDetailPage({
    super.key,
    required this.book,
    this.heroTag,
    this.searchResults,
  });

  @override
  State<BookDetailPage> createState() => _BookDetailPageState();
}

class _BookDetailPageState extends State<BookDetailPage> {
  bool _descExpanded = false;
  List<Book> _recommendations = [];
  bool _loadingRec = false; // 仅从收藏页打开（无搜索结果）时按作者搜索推荐

  @override
  void initState() {
    super.initState();
    BookDownloadService().addListener(_onChanged);
    BookFavoritesService().addListener(_onChanged);
    _initRecommendations();
  }

  /// 推荐图书：有传入搜索结果（从搜索页打开）则直接随机取 5 本，不发请求；
  /// 无搜索结果（从收藏页打开）则以作者为条件搜索后随机取 5 本。
  void _initRecommendations() {
    final src = widget.searchResults;
    if (src != null && src.isNotEmpty) {
      final others = src.where((b) => b.id != widget.book.id).toList();
      others.shuffle(Random());
      _recommendations = others.take(5).toList();
      return;
    }
    _loadRecommendationsByAuthor();
  }

  Future<void> _loadRecommendationsByAuthor() async {
    final keyword =
        (widget.book.author != null && widget.book.author!.isNotEmpty)
        ? widget.book.author!
        : widget.book.title;
    if (keyword.isEmpty) return;
    setState(() => _loadingRec = true);
    try {
      final result = await ZlibraryService().search(keyword, limit: 30);
      final others = result.items.where((b) => b.id != widget.book.id).toList();
      others.shuffle(Random());
      if (mounted) {
        setState(() {
          _recommendations = others.take(5).toList();
          _loadingRec = false;
        });
      }
    } catch (_) {
      if (mounted) setState(() => _loadingRec = false);
    }
  }

  @override
  void dispose() {
    BookDownloadService().removeListener(_onChanged);
    BookFavoritesService().removeListener(_onChanged);
    super.dispose();
  }

  void _onChanged() {
    if (mounted) setState(() {});
  }

  Future<void> _onDownload() async {
    var result = await BookDownloadService().download(widget.book);
    if (!mounted) return;
    // 关闭内置账号且未登录：弹登录框，登录成功后自动重新下载
    if (result == BookDownloadResult.needLogin) {
      final ok = await Navigator.push<bool>(
        context,
        MaterialPageRoute(builder: (_) => const ZlibraryAuthPage()),
      );
      if (ok == true && mounted) {
        result = await BookDownloadService().download(widget.book);
      }
    }
    if (!mounted) return;
    final msg = switch (result) {
      BookDownloadResult.started => '已加入下载队列',
      BookDownloadResult.alreadyDownloading => '已在下载队列中',
      BookDownloadResult.limitExceeded => _limitExceededMsg(),
      BookDownloadResult.needLogin => '请先登录账号后再下载',
    };
    _toast(msg);
  }

  String _limitExceededMsg() {
    final z = ZlibraryService();
    // 登录态限额优先用服务端实际值，未取到回退硬编码
    final loggedLimit =
        z.serverDownloadsLimit ?? ZlibraryService.loggedDailyLimit;
    return z.isLoggedIn
        ? '今日下载已达 $loggedLimit 本上限，请明天再试'
        : '今日内置账号下载已达 ${ZlibraryService.builtinDailyLimit} 本上限，登录自有账号可下载更多';
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

  /// 去除 z-library 简介里的 HTML 标签，保留段落换行
  String _stripHtml(String html) {
    var s = html;
    s = s.replaceAll(RegExp(r'<br\s*/?>', caseSensitive: false), '\n');
    s = s.replaceAll(RegExp(r'</p>', caseSensitive: false), '\n');
    s = s.replaceAll(RegExp(r'<[^>]+>'), '');
    s = s.replaceAll('&nbsp;', ' ');
    s = s.replaceAll('&amp;', '&');
    s = s.replaceAll('&lt;', '<');
    s = s.replaceAll('&gt;', '>');
    s = s.replaceAll('&quot;', '"');
    s = s.replaceAll('&#39;', "'");
    return s.replaceAll(RegExp(r'\n{3,}'), '\n\n').trim();
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Scaffold(
      body: CustomScrollView(
        slivers: [
          SliverAppBar(
            pinned: true,
            title: Text(
              widget.book.title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 16),
            ),
          ),
          SliverToBoxAdapter(child: _buildContent(isDark)),
          SliverToBoxAdapter(child: _buildDownloadCard(isDark)),
          SliverToBoxAdapter(child: _buildRecommendations(isDark)),
          const SliverToBoxAdapter(child: SizedBox(height: 32)),
        ],
      ),
    );
  }

  Widget _buildCover(bool isDark, {double width = 180}) {
    final cover = ClipRRect(
      borderRadius: BorderRadius.circular(12),
      child: SizedBox(
        width: width,
        child: AspectRatio(
          aspectRatio: 3 / 4,
          child: (widget.book.cover ?? '').isEmpty
              ? Container(
                  color: isDark ? JellyTheme.cardDark : Colors.grey[200],
                  child: const Icon(
                    Icons.menu_book_rounded,
                    size: 56,
                    color: Colors.grey,
                  ),
                )
              : CachedNetworkImage(
                  imageUrl: widget.book.cover!,
                  fit: BoxFit.cover,
                  placeholder: (c, u) => Container(
                    color: isDark ? JellyTheme.cardDark : Colors.grey[200],
                  ),
                  errorWidget: (c, u, e) => Container(
                    color: isDark ? JellyTheme.cardDark : Colors.grey[200],
                    child: const Icon(
                      Icons.broken_image,
                      size: 48,
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

  Widget _buildContent(bool isDark) {
    final titleColor = isDark ? Colors.white : JellyTheme.textPrimaryLight;
    final secondaryColor = isDark ? Colors.white70 : JellyTheme.textSecondary;
    final book = widget.book;

    final desc = book.description == null
        ? null
        : _stripHtml(book.description!);

    final downloadTask = BookDownloadService().task(book.id);
    final downloadCompleted =
        downloadTask?.status == BookDownloadStatus.completed;

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 40, vertical: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          // 封面独占顶部
          Center(child: _buildCover(isDark)),
          const SizedBox(height: 16),
          // 标题
          Text(
            book.title,
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: 22,
              fontWeight: FontWeight.bold,
              color: titleColor,
              height: 1.3,
            ),
          ),
          // 作者
          if (book.author != null && book.author!.isNotEmpty) ...[
            const SizedBox(height: 8),
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(Icons.person_outline, size: 16, color: secondaryColor),
                const SizedBox(width: 4),
                Flexible(
                  child: Text(
                    book.author!,
                    style: TextStyle(fontSize: 14, color: secondaryColor),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
            ),
          ],
          // 评分
          if (book.interestScore != null && book.interestScore! > 0) ...[
            const SizedBox(height: 8),
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                const Icon(Icons.star_rounded, size: 16, color: Colors.amber),
                const SizedBox(width: 4),
                Text(
                  book.interestScore!.toStringAsFixed(1),
                  style: const TextStyle(
                    fontSize: 13,
                    color: Colors.amber,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(width: 4),
                Text(
                  '兴趣评分',
                  style: TextStyle(fontSize: 11, color: secondaryColor),
                ),
              ],
            ),
          ],
          const SizedBox(height: 14),
          // 元信息 chips
          Wrap(
            alignment: WrapAlignment.center,
            spacing: 8,
            runSpacing: 8,
            children: [
              if (book.extension != null && book.extension!.isNotEmpty)
                _chip(book.extension!.toUpperCase(), isDark, highlight: true),
              if (book.year != null && book.year!.isNotEmpty)
                _chip(book.year!, isDark),
              if (book.language != null && book.language!.isNotEmpty)
                _chip(book.language!, isDark),
              if (book.filesizeString != null &&
                  book.filesizeString!.isNotEmpty)
                _chip(book.filesizeString!, isDark),
              if (_pagesInt(book) > 0) _chip('${_pagesInt(book)} 页', isDark),
              if (book.publisher != null && book.publisher!.isNotEmpty)
                _chip(book.publisher!, isDark),
              if (book.identifier != null && book.identifier!.isNotEmpty)
                _chip('ISBN: ${book.identifier}', isDark),
            ],
          ),
          const SizedBox(height: 16),
          // 收藏 / 书架 / 阅读(或下载) 胶囊；已下载时「重新下载」换行显示
          Column(
            children: [
              Wrap(
                alignment: WrapAlignment.center,
                spacing: 10,
                runSpacing: 8,
                children: [
                  _buildFavoriteCapsule(),
                  _buildBookshelfCapsule(),
                  _buildDownloadCapsule(downloadTask),
                ],
              ),
              if (downloadCompleted) ...[
                const SizedBox(height: 10),
                _buildRedownloadButton(),
              ],
            ],
          ),
          // 简介
          if (desc != null && desc.isNotEmpty) ...[
            const SizedBox(height: 20),
            _buildSynopsis(desc, titleColor, secondaryColor),
          ],
        ],
      ),
    );
  }

  int _pagesInt(Book book) {
    final v = book.pages;
    if (v == null || v.isEmpty) return 0;
    return int.tryParse(v) ?? 0;
  }

  Widget _chip(String text, bool isDark, {bool highlight = false}) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
        color: highlight
            ? JellyTheme.primary.withValues(alpha: 0.15)
            : (isDark
                  ? Colors.white.withValues(alpha: 0.08)
                  : Colors.black.withValues(alpha: 0.05)),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Text(
        text,
        style: TextStyle(
          fontSize: 12,
          color: highlight
              ? JellyTheme.primary
              : (isDark ? Colors.white70 : JellyTheme.textSecondary),
          fontWeight: highlight ? FontWeight.w700 : FontWeight.w500,
        ),
      ),
    );
  }

  Widget _buildCapsule({
    required IconData icon,
    required String label,
    required VoidCallback onTap,
    Color color = JellyTheme.primary,
  }) {
    return Material(
      color: color,
      borderRadius: BorderRadius.circular(20),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 15, color: Colors.white),
              const SizedBox(width: 4),
              Text(
                label,
                style: const TextStyle(
                  fontSize: 13,
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

  Widget _buildFavoriteCapsule() {
    final fav = BookFavoritesService().isFavorite(widget.book.id);
    return _buildCapsule(
      icon: fav ? Icons.favorite : Icons.favorite_border,
      label: fav ? '已收藏' : '收藏',
      color: fav ? const Color(0xFFFF8B94) : JellyTheme.primary,
      onTap: () {
        BookFavoritesService().toggle(widget.book);
        _toast(fav ? '已取消收藏' : '已收藏');
      },
    );
  }

  Widget _buildBookshelfCapsule() {
    return ListenableBuilder(
      listenable: BookshelfService(),
      builder: (context, _) {
        final inShelf = BookshelfService()
            .getBookshelvesForItem(widget.book.id, BookshelfItemType.book)
            .isNotEmpty;
        return _buildCapsule(
          icon: inShelf
              ? Icons.library_books_rounded
              : Icons.library_add_rounded,
          label: inShelf ? '已加书架' : '书架',
          color: inShelf ? const Color(0xFF7C8CFF) : JellyTheme.primary,
          onTap: () async {
            final hasReadingProgress =
                BookReadingProgressService().getProgress(widget.book.id) !=
                null;
            final result = await showBookshelfDialog(
              context,
              itemId: widget.book.id,
              type: BookshelfItemType.book,
              title: '加入书架',
              meta: jsonEncode(widget.book.toJson()),
              disabledShelfIds: hasReadingProgress
                  ? null
                  : {BookshelfService.presetReading},
            );
            if (result != null && mounted) {
              _toast(result.isEmpty ? '已从所有书架移除' : '已加入 ${result.length} 个书架');
            }
          },
        );
      },
    );
  }

  Widget _buildDownloadCapsule(BookDownloadTask? task) {
    final completed = task?.status == BookDownloadStatus.completed;
    if (completed && task != null) {
      return _buildCapsule(
        icon: Icons.menu_book_rounded,
        label: '阅读',
        onTap: () => BookReaderPage.open(context, task),
      );
    }
    return _buildCapsule(
      icon: Icons.download_for_offline,
      label: '下载',
      onTap: _onDownload,
    );
  }

  Widget _buildRedownloadButton() {
    return IconButton(
      tooltip: '重新下载',
      iconSize: 20,
      padding: EdgeInsets.zero,
      constraints: const BoxConstraints(minWidth: 36, minHeight: 36),
      icon: const Icon(Icons.download_for_offline, color: JellyTheme.primary),
      onPressed: _onDownload,
    );
  }

  Widget _buildSynopsis(String desc, Color titleColor, Color secondaryColor) {
    final likelyLong = desc.length > 80 || desc.contains('\n');
    return Column(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        Text(
          '简介',
          textAlign: TextAlign.center,
          style: TextStyle(
            fontSize: 15,
            fontWeight: FontWeight.w700,
            color: titleColor,
          ),
        ),
        const SizedBox(height: 8),
        Text(
          desc,
          textAlign: TextAlign.center,
          maxLines: _descExpanded ? null : 4,
          overflow: _descExpanded ? TextOverflow.clip : TextOverflow.ellipsis,
          style: TextStyle(fontSize: 13, height: 1.6, color: secondaryColor),
        ),
        if (likelyLong)
          TextButton(
            onPressed: () => setState(() => _descExpanded = !_descExpanded),
            style: TextButton.styleFrom(
              minimumSize: const Size(0, 28),
              padding: const EdgeInsets.symmetric(horizontal: 8),
              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
            ),
            child: Text(
              _descExpanded ? '收起' : '展开全部',
              style: const TextStyle(fontSize: 12),
            ),
          ),
      ],
    );
  }

  /// 下载状态卡片：仅在排队/下载中/暂停/失败时显示（不显示「已下载」与删除按钮）
  Widget _buildDownloadCard(bool isDark) {
    final task = BookDownloadService().task(widget.book.id);
    if (task == null || task.status == BookDownloadStatus.completed) {
      return const SizedBox.shrink();
    }
    final titleColor = isDark ? Colors.white : JellyTheme.textPrimaryLight;
    return Padding(
      padding: const EdgeInsets.fromLTRB(40, 8, 40, 0),
      child: Container(
        decoration: BoxDecoration(
          color: isDark ? JellyTheme.cardDark : JellyTheme.cardLight,
          borderRadius: BorderRadius.circular(16),
        ),
        clipBehavior: Clip.antiAlias,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(14, 14, 14, 0),
              child: Row(
                children: [
                  Icon(
                    _statusIcon(task.status),
                    size: 18,
                    color: _statusColor(task.status),
                  ),
                  const SizedBox(width: 6),
                  Text(
                    _statusText(task),
                    style: TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                      color: titleColor,
                    ),
                  ),
                  const Spacer(),
                  ..._buildActions(task),
                ],
              ),
            ),
            if (task.status == BookDownloadStatus.downloading ||
                task.status == BookDownloadStatus.queued) ...[
              const SizedBox(height: 10),
              // 进度条左右留边，与状态行对齐
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 14),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(4),
                  child: LinearProgressIndicator(
                    value: task.status == BookDownloadStatus.queued
                        ? null
                        : task.progress,
                    minHeight: 6,
                    backgroundColor: (isDark ? Colors.white : Colors.black)
                        .withValues(alpha: 0.1),
                    color: JellyTheme.primary,
                  ),
                ),
              ),
            ],
            if (task.status == BookDownloadStatus.failed &&
                task.error != null) ...[
              const SizedBox(height: 6),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 14),
                child: Text(
                  '失败：${task.error}',
                  style: const TextStyle(fontSize: 12, color: JellyTheme.error),
                ),
              ),
            ],
            const SizedBox(height: 14),
          ],
        ),
      ),
    );
  }

  IconData _statusIcon(BookDownloadStatus s) {
    switch (s) {
      case BookDownloadStatus.queued:
        return Icons.hourglass_top_rounded;
      case BookDownloadStatus.downloading:
        return Icons.downloading_rounded;
      case BookDownloadStatus.completed:
        return Icons.check_circle_rounded;
      case BookDownloadStatus.failed:
        return Icons.error_outline_rounded;
      case BookDownloadStatus.paused:
        return Icons.pause_circle_rounded;
    }
  }

  Color _statusColor(BookDownloadStatus s) {
    switch (s) {
      case BookDownloadStatus.completed:
        return JellyTheme.success;
      case BookDownloadStatus.failed:
        return JellyTheme.error;
      case BookDownloadStatus.downloading:
        return JellyTheme.primary;
      case BookDownloadStatus.queued:
      case BookDownloadStatus.paused:
        return JellyTheme.textSecondary;
    }
  }

  String _statusText(BookDownloadTask t) {
    switch (t.status) {
      case BookDownloadStatus.queued:
        return '排队中';
      case BookDownloadStatus.downloading:
        return '下载中 ${(t.progress * 100).toInt()}%';
      case BookDownloadStatus.completed:
        return '已下载';
      case BookDownloadStatus.failed:
        return '下载失败';
      case BookDownloadStatus.paused:
        return '已暂停';
    }
  }

  List<Widget> _buildActions(BookDownloadTask t) {
    const density = VisualDensity.compact;
    switch (t.status) {
      case BookDownloadStatus.queued:
      case BookDownloadStatus.downloading:
        return [
          IconButton(
            icon: const Icon(Icons.pause_rounded, size: 20),
            tooltip: '暂停',
            onPressed: () => BookDownloadService().pauseTask(t.bookId),
            visualDensity: density,
          ),
          IconButton(
            icon: const Icon(Icons.close_rounded, size: 20),
            tooltip: '取消',
            onPressed: () => BookDownloadService().cancelTask(t.bookId),
            visualDensity: density,
          ),
        ];
      case BookDownloadStatus.paused:
        return [
          IconButton(
            icon: const Icon(Icons.play_arrow_rounded, size: 20),
            tooltip: '继续',
            onPressed: () => BookDownloadService().resumeTask(t.bookId),
            visualDensity: density,
          ),
          IconButton(
            icon: const Icon(Icons.close_rounded, size: 20),
            tooltip: '取消',
            onPressed: () => BookDownloadService().cancelTask(t.bookId),
            visualDensity: density,
          ),
        ];
      case BookDownloadStatus.failed:
        return [
          IconButton(
            icon: const Icon(Icons.refresh_rounded, size: 20),
            tooltip: '重试',
            onPressed: () => BookDownloadService().retryTask(t.bookId),
            visualDensity: density,
          ),
          IconButton(
            icon: const Icon(Icons.close_rounded, size: 20),
            tooltip: '取消',
            onPressed: () => BookDownloadService().cancelTask(t.bookId),
            visualDensity: density,
          ),
        ];
      case BookDownloadStatus.completed:
        // 详情页不显示已下载/删除，完成态卡片已隐藏
        return [];
    }
  }

  /// 推荐图书区：整体水平居中；从搜索结果或按作者搜索随机取 5 本
  Widget _buildRecommendations(bool isDark) {
    final titleColor = isDark ? Colors.white : JellyTheme.textPrimaryLight;
    if (_loadingRec) {
      return const Padding(
        padding: EdgeInsets.all(24),
        child: Center(
          child: CircularProgressIndicator(
            strokeWidth: 2,
            color: JellyTheme.primary,
          ),
        ),
      );
    }
    if (_recommendations.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.fromLTRB(40, 16, 40, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Text(
            '推荐图书',
            style: TextStyle(
              fontSize: 15,
              fontWeight: FontWeight.w700,
              color: titleColor,
            ),
          ),
          const SizedBox(height: 10),
          SizedBox(
            height: 165,
            child: LayoutBuilder(
              builder: (context, constraints) {
                return SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  child: ConstrainedBox(
                    constraints: BoxConstraints(minWidth: constraints.maxWidth),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      mainAxisSize: MainAxisSize.max,
                      children: [
                        for (var i = 0; i < _recommendations.length; i++) ...[
                          if (i > 0) const SizedBox(width: 10),
                          _buildRecCard(_recommendations[i], isDark),
                        ],
                      ],
                    ),
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildRecCard(Book b, bool isDark) {
    final titleColor = isDark ? Colors.white70 : JellyTheme.textSecondary;
    return GestureDetector(
      onTap: () => Navigator.push(
        context,
        MaterialPageRoute(builder: (_) => BookDetailPage(book: b)),
      ),
      child: SizedBox(
        width: 92,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(8),
              child: (b.cover ?? '').isEmpty
                  ? Container(
                      width: 92,
                      height: 124,
                      color: isDark ? JellyTheme.cardDark : Colors.grey[200],
                      child: const Icon(
                        Icons.menu_book_rounded,
                        size: 28,
                        color: Colors.grey,
                      ),
                    )
                  : CachedNetworkImage(
                      imageUrl: b.cover!,
                      width: 92,
                      height: 124,
                      fit: BoxFit.cover,
                      placeholder: (c, u) => Container(
                        width: 92,
                        height: 124,
                        color: isDark ? JellyTheme.cardDark : Colors.grey[200],
                      ),
                      errorWidget: (c, u, e) => Container(
                        width: 92,
                        height: 124,
                        color: isDark ? JellyTheme.cardDark : Colors.grey[200],
                        child: const Icon(
                          Icons.broken_image,
                          size: 24,
                          color: Colors.grey,
                        ),
                      ),
                    ),
            ),
            const SizedBox(height: 6),
            Text(
              b.title,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 11, height: 1.3, color: titleColor),
            ),
          ],
        ),
      ),
    );
  }
}
