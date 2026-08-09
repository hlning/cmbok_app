import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import '../models/comic.dart';
import '../theme/jelly_theme.dart';
import 'jelly_favorite_button.dart';
import 'jelly_score_badge.dart';

/// 果冻风漫画列表项（横向：封面 + 信息，用于列表视图）
class JellyComicListTile extends StatefulWidget {
  final Comic comic;
  final VoidCallback onTap;

  /// 长按回调（用于父级进入多选模式；为空则不启用长按）
  final VoidCallback? onLongPress;

  /// 封面 Hero 动画 tag（与详情页一致；为空则不启用共享元素过渡）
  final String? heroTag;

  const JellyComicListTile({
    super.key,
    required this.comic,
    required this.onTap,
    this.onLongPress,
    this.heroTag,
  });

  @override
  State<JellyComicListTile> createState() => _JellyComicListTileState();
}

class _JellyComicListTileState extends State<JellyComicListTile>
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
      end: 0.97,
    ).animate(CurvedAnimation(parent: _controller, curve: Curves.easeInOut));
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _onTapDown(TapDownDetails details) {
    setState(() => _isPressed = true);
    _controller.forward();
  }

  void _onTapUp(TapUpDetails details) {
    setState(() => _isPressed = false);
    _controller.reverse();
    widget.onTap();
  }

  void _onTapCancel() {
    setState(() => _isPressed = false);
    _controller.reverse();
  }

  /// 封面图按需包裹 Hero（heroTag 为空则不启用共享元素过渡）
  Widget _maybeHero(Widget child) {
    final tag = widget.heroTag;
    return tag == null ? child : Hero(tag: tag, child: child);
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final comic = widget.comic;

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
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              // 封面：固定 3:4 尺寸，避免依赖网络图片尺寸导致布局抖动/卡死
              _maybeHero(
                SizedBox(
                  width: 84,
                  height: 112,
                  child: CachedNetworkImage(
                    imageUrl: comic.cover,
                    fit: BoxFit.cover,
                    placeholder: (context, url) => Container(
                      color: isDark ? Colors.grey[800] : Colors.grey[200],
                      child: const Center(
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: JellyTheme.primary,
                        ),
                      ),
                    ),
                    errorWidget: (context, url, error) => Container(
                      color: isDark ? Colors.grey[800] : Colors.grey[200],
                      child: const Icon(Icons.broken_image, color: Colors.grey),
                    ),
                  ),
                ),
              ),
              // 信息区
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      // 标题 + 热度（同一行）
                      Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Expanded(
                            child: Text(
                              comic.title,
                              style: TextStyle(
                                fontSize: 15,
                                fontWeight: FontWeight.w700,
                                color: isDark
                                    ? Colors.white
                                    : JellyTheme.textPrimaryLight,
                              ),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                          if (comicHasScore(comic)) ...[
                            const SizedBox(width: 8),
                            JellyScoreBadge(comic: comic, isDark: isDark),
                          ],
                        ],
                      ),
                      const SizedBox(height: 6),
                      // 作者 + 收藏（同一行，收藏靠右，与表格视图一致）
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          if (comic.author != null && comic.author!.isNotEmpty)
                            Flexible(
                              child: Container(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 8,
                                  vertical: 3,
                                ),
                                decoration: BoxDecoration(
                                  color: JellyTheme.primary.withValues(
                                    alpha: 0.15,
                                  ),
                                  borderRadius: BorderRadius.circular(8),
                                ),
                                child: Text(
                                  comic.author!,
                                  style: const TextStyle(
                                    fontSize: 11,
                                    color: JellyTheme.primary,
                                    fontWeight: FontWeight.w500,
                                  ),
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                            )
                          else
                            const SizedBox.shrink(),
                          JellyFavoriteButton(comic: comic, size: 20),
                        ],
                      ),
                      const SizedBox(height: 6),
                      // 描述区：固定 2 行高度，优先显示简介，无简介时显示别名
                      SizedBox(
                        height: 11 * 1.4 * 2, // fontSize:11, height:1.4, 2行
                        child: Text(
                          (comic.description != null &&
                                  comic.description!.trim().isNotEmpty)
                              ? comic.description!.trim()
                              : (comic.alias != null && comic.alias!.isNotEmpty)
                              ? '别名：${comic.alias}'
                              : '',
                          style: TextStyle(
                            fontSize: 11,
                            height: 1.4,
                            color: isDark
                                ? Colors.white54
                                : JellyTheme.textSecondary,
                          ),
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      // 底部信息行：章节数 / 更新时间
                      if (_hasMeta(comic))
                        Wrap(
                          spacing: 10,
                          runSpacing: 4,
                          crossAxisAlignment: WrapCrossAlignment.center,
                          children: [
                            if (comic.totalChapters != null &&
                                comic.totalChapters! > 0)
                              _MetaItem(
                                icon: Icons.menu_book_rounded,
                                text: '共 ${comic.totalChapters} 章',
                                isDark: isDark,
                              ),
                            if (comic.updateTime != null)
                              _MetaItem(
                                icon: Icons.update_rounded,
                                text: _formatDate(comic.updateTime!),
                                isDark: isDark,
                              ),
                          ],
                        ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  bool _hasMeta(Comic comic) {
    final hasChapters = comic.totalChapters != null && comic.totalChapters! > 0;
    final hasUpdate = comic.updateTime != null;
    return hasChapters || hasUpdate;
  }

  String _formatDate(DateTime d) {
    String two(int v) => v.toString().padLeft(2, '0');
    return '${d.year}-${two(d.month)}-${two(d.day)}';
  }
}

/// 普通信息项（图标 + 文字）
class _MetaItem extends StatelessWidget {
  final IconData icon;
  final String text;
  final bool isDark;

  const _MetaItem({
    required this.icon,
    required this.text,
    required this.isDark,
  });

  @override
  Widget build(BuildContext context) {
    final color = isDark ? Colors.white54 : JellyTheme.textSecondary;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 13, color: color),
        const SizedBox(width: 3),
        Text(
          text,
          style: TextStyle(fontSize: 11, color: color),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
      ],
    );
  }
}
