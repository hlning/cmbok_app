import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import '../models/book.dart';
import '../services/book_favorites_service.dart';
import '../services/book_reading_progress_service.dart';
import '../theme/jelly_theme.dart';

/// 果冻风图书卡片（grid / list 两态）
/// 布局同漫画主卡片：封面 + 书名 + 作者 + 元信息 + 收藏按钮；点击进入详情页。
/// 无下载按钮（下载在详情页），无章节按钮。
class JellyBookCard extends StatefulWidget {
  final Book book;
  final bool isGrid;
  final VoidCallback? onTap;

  /// 长按回调（用于父级进入多选模式；为空则不启用长按）
  final VoidCallback? onLongPress;

  /// 封面 Hero 动画 tag（与详情页一致；为空则不启用共享元素过渡）
  final String? heroTag;

  const JellyBookCard({
    super.key,
    required this.book,
    required this.isGrid,
    this.onTap,
    this.onLongPress,
    this.heroTag,
  });

  @override
  State<JellyBookCard> createState() => _JellyBookCardState();
}

class _JellyBookCardState extends State<JellyBookCard>
    with SingleTickerProviderStateMixin {
  late AnimationController _controller;
  late Animation<double> _scaleAnimation;
  bool _isPressed = false;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      duration: const Duration(milliseconds: 150),
      vsync: this,
    );
    _scaleAnimation = Tween<double>(
      begin: 1.0,
      end: widget.isGrid ? 0.95 : 0.97,
    ).animate(CurvedAnimation(parent: _controller, curve: Curves.easeInOut));
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _onTapDown(TapDownDetails d) {
    setState(() => _isPressed = true);
    _controller.forward();
  }

  void _onTapUp(TapUpDetails d) {
    setState(() => _isPressed = false);
    _controller.reverse();
    widget.onTap?.call();
  }

  void _onTapCancel() {
    setState(() => _isPressed = false);
    _controller.reverse();
  }

  Widget _maybeHero(Widget child) {
    final tag = widget.heroTag;
    return tag == null ? child : Hero(tag: tag, child: child);
  }

  /// 次要元信息（年份 · 语言）；格式已在角标显示，文件大小单独高亮
  String get _secondaryMeta {
    final parts = <String>[];
    if (widget.book.year != null && widget.book.year!.isNotEmpty) {
      parts.add(widget.book.year!);
    }
    if (widget.book.language != null && widget.book.language!.isNotEmpty) {
      parts.add(widget.book.language!);
    }
    return parts.join(' · ');
  }

  /// 阅读百分比（0~1，与阅读器 HUD 同为页维度）；无进度记录或旧数据无页总数返回 null。
  double? get _readPercent {
    final p = BookReadingProgressService().getProgress(widget.book.id);
    if (p == null || p.pageTotal <= 0) return null;
    return ((p.pageIndex + 1) / p.pageTotal).clamp(0.0, 1.0);
  }

  /// 元信息行：文件大小优先（高亮主色加粗）+ 年份/语言（次要）
  Widget _buildMetaRow(bool isDark, {double fontSize = 11}) {
    final secondary = isDark ? Colors.white54 : JellyTheme.textSecondary;
    final secondaryText = _secondaryMeta;
    final size = widget.book.filesizeString;
    final hasSize = size != null && size.isNotEmpty;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (hasSize)
          Text(
            size,
            style: TextStyle(
              fontSize: fontSize,
              fontWeight: FontWeight.w700,
              color: JellyTheme.primary,
            ),
          ),
        if (hasSize && secondaryText.isNotEmpty) const SizedBox(width: 6),
        if (secondaryText.isNotEmpty)
          Flexible(
            child: Text(
              secondaryText,
              style: TextStyle(fontSize: fontSize, color: secondary),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
      ],
    );
  }

  String get _extBadge =>
      (widget.book.extension != null && widget.book.extension!.isNotEmpty)
      ? widget.book.extension!.toUpperCase()
      : 'BOOK';

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return GestureDetector(
      onTapDown: _onTapDown,
      onTapUp: _onTapUp,
      onTapCancel: _onTapCancel,
      onLongPress: widget.onLongPress == null
          ? null
          : () {
              setState(() => _isPressed = false);
              _controller.reverse();
              widget.onLongPress!();
            },
      child: AnimatedBuilder(
        animation: _scaleAnimation,
        builder: (context, child) {
          return Transform.scale(
            scale: _scaleAnimation.value,
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 200),
              curve: Curves.easeOut,
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(20),
                color: isDark ? JellyTheme.cardDark : JellyTheme.cardLight,
                boxShadow: _isPressed
                    ? [
                        BoxShadow(
                          color: JellyTheme.primary.withValues(alpha: 0.2),
                          blurRadius: 10,
                          spreadRadius: 1,
                          offset: const Offset(0, 3),
                        ),
                      ]
                    : [
                        BoxShadow(
                          color: JellyTheme.primary.withValues(alpha: 0.15),
                          blurRadius: 15,
                          spreadRadius: 2,
                          offset: const Offset(0, 6),
                        ),
                      ],
              ),
              child: child,
            ),
          );
        },
        child: ClipRRect(
          borderRadius: BorderRadius.circular(20),
          child: widget.isGrid ? _buildGrid(isDark) : _buildList(isDark),
        ),
      ),
    );
  }

  Widget _coverWidget(bool isDark, {double? width, double? height}) {
    final coverUrl = widget.book.cover ?? '';
    return coverUrl.isEmpty
        ? Container(
            color: isDark ? Colors.grey[800] : Colors.grey[200],
            width: width,
            height: height,
            child: const Icon(
              Icons.menu_book_rounded,
              size: 32,
              color: Colors.grey,
            ),
          )
        : CachedNetworkImage(
            imageUrl: coverUrl,
            fit: BoxFit.cover,
            memCacheWidth: 300,
            width: width,
            height: height,
            placeholder: (c, u) => Container(
              color: isDark ? Colors.grey[800] : Colors.grey[200],
              width: width,
              height: height,
              child: Center(
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  color: JellyTheme.primary,
                ),
              ),
            ),
            errorWidget: (c, u, e) => Container(
              color: isDark ? Colors.grey[800] : Colors.grey[200],
              width: width,
              height: height,
              child: const Icon(
                Icons.menu_book_rounded,
                size: 32,
                color: Colors.grey,
              ),
            ),
          );
  }

  /// 收藏按钮（跟随 BookFavoritesService 状态切换）
  Widget _buildFavoriteButton() {
    return ListenableBuilder(
      listenable: BookFavoritesService(),
      builder: (context, _) {
        final fav = BookFavoritesService().isFavorite(widget.book.id);
        return IconButton(
          icon: AnimatedSwitcher(
            duration: const Duration(milliseconds: 200),
            transitionBuilder: (child, anim) =>
                ScaleTransition(scale: anim, child: child),
            child: Icon(
              fav ? Icons.favorite_rounded : Icons.favorite_border_rounded,
              key: ValueKey(fav),
              color: fav ? JellyTheme.error : JellyTheme.primary,
              size: 20,
            ),
          ),
          padding: EdgeInsets.zero,
          constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
          onPressed: () => BookFavoritesService().toggle(widget.book),
          tooltip: fav ? '取消收藏' : '收藏',
        );
      },
    );
  }

  Widget _buildGrid(bool isDark) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        AspectRatio(
          aspectRatio: 3 / 4,
          child: Stack(
            fit: StackFit.expand,
            children: [
              _maybeHero(_coverWidget(isDark)),
              Positioned(
                bottom: 0,
                left: 0,
                right: 0,
                height: 50,
                child: Container(
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      colors: [
                        Colors.transparent,
                        Colors.black.withValues(alpha: 0.7),
                      ],
                    ),
                  ),
                ),
              ),
              Positioned(
                top: 6,
                left: 6,
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 6,
                    vertical: 2,
                  ),
                  decoration: BoxDecoration(
                    color: JellyTheme.primary.withValues(alpha: 0.9),
                    borderRadius: BorderRadius.circular(5),
                  ),
                  child: Text(
                    _extBadge,
                    style: const TextStyle(
                      fontSize: 9,
                      color: Colors.white,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(10, 8, 4, 8),
          child: SizedBox(
            height: 50,
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        widget.book.title,
                        style: TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                          color: isDark
                              ? Colors.white
                              : JellyTheme.textPrimaryLight,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      const SizedBox(height: 4),
                      _buildMetaRow(isDark, fontSize: 10),
                    ],
                  ),
                ),
                _buildFavoriteButton(),
              ],
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildList(bool isDark) {
    final readPct = _readPercent;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        _maybeHero(
          SizedBox(
            width: 84,
            height: 112,
            child: _coverWidget(isDark, width: 84, height: 112),
          ),
        ),
        Expanded(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(12, 10, 8, 10),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  widget.book.title,
                  style: TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w700,
                    color: isDark ? Colors.white : JellyTheme.textPrimaryLight,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                const SizedBox(height: 6),
                if (widget.book.author != null &&
                    widget.book.author!.isNotEmpty) ...[
                  Text(
                    widget.book.author!,
                    style: TextStyle(
                      fontSize: 12,
                      color: isDark ? Colors.white54 : JellyTheme.textSecondary,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  const SizedBox(height: 6),
                ],
                _buildMetaRow(isDark, fontSize: 11),
                if (readPct != null) ...[
                  const SizedBox(height: 4),
                  Text(
                    '已读 ${(readPct * 100).toInt()}%',
                    style: TextStyle(
                      fontSize: 10,
                      color: JellyTheme.primary,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
        // 右侧：格式标签 + 收藏按钮 垂直对齐
        Padding(
          padding: const EdgeInsets.only(right: 8),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                decoration: BoxDecoration(
                  color: JellyTheme.primary.withValues(alpha: 0.15),
                  borderRadius: BorderRadius.circular(5),
                ),
                child: Text(
                  _extBadge,
                  style: TextStyle(
                    fontSize: 10,
                    color: JellyTheme.primary,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              const SizedBox(height: 8),
              _buildFavoriteButton(),
            ],
          ),
        ),
      ],
    );
  }
}

/// 图书封面 Hero 动画 tag（区分来源页面，避免同书 tag 冲突）
String bookCoverHeroTag(String prefix, Book book) => '$prefix-book-${book.id}';
