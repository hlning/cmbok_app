import 'package:flutter/material.dart';
import '../models/comic.dart';
import '../services/favorites_service.dart';
import '../theme/jelly_theme.dart';

/// 收藏按钮（心形，点击切换收藏；带缩放动画）
/// 样式与图书卡片 [JellyBookCard] 内的收藏按钮一致：
/// favorite_border/favorite_rounded + 主色/错误色。
/// 采用紧凑布局（Padding(4)+Icon，无 48px 触控下限），
/// 保证在漫画网格卡「评分徽章 + 收藏按钮」的固定高度（50）信息区内不溢出。
class JellyFavoriteButton extends StatelessWidget {
  final Comic comic;
  final double size;

  const JellyFavoriteButton({super.key, required this.comic, this.size = 20});

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: FavoritesService(),
      builder: (context, _) {
        final fav = FavoritesService().isFavorite(comic.id);
        return GestureDetector(
          onTap: () => FavoritesService().toggle(comic),
          behavior: HitTestBehavior.opaque,
          child: Padding(
            padding: const EdgeInsets.all(4),
            child: AnimatedSwitcher(
              duration: const Duration(milliseconds: 200),
              transitionBuilder: (child, anim) =>
                  ScaleTransition(scale: anim, child: child),
              child: Icon(
                fav ? Icons.favorite_rounded : Icons.favorite_border_rounded,
                key: ValueKey(fav),
                color: fav ? JellyTheme.error : JellyTheme.primary,
                size: size,
              ),
            ),
          ),
        );
      },
    );
  }
}
