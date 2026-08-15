import 'package:flutter/material.dart';
import '../models/comic.dart';

/// 是否有可显示的评分 / 热度
bool comicHasScore(Comic comic) {
  final hasRating = comic.rating != null && comic.rating! > 0;
  final hasPopular = comic.popular != null && comic.popular! > 0;
  return hasRating || hasPopular;
}

/// 评分 / 热度徽章：
/// 有评分时显示 星 + 分数；否则显示 热度（火 + 数值）。
class JellyScoreBadge extends StatelessWidget {
  final Comic comic;
  final bool isDark;

  const JellyScoreBadge({super.key, required this.comic, required this.isDark});

  @override
  Widget build(BuildContext context) {
    if (comic.rating != null && comic.rating! > 0) {
      return Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.star_rounded, size: 13, color: Color(0xFFFFB400)),
          const SizedBox(width: 2),
          Text(
            comic.rating!.toStringAsFixed(1),
            style: const TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.w700,
              color: Color(0xFFFFB400),
            ),
          ),
        ],
      );
    }
    if (comic.popular != null && comic.popular! > 0) {
      return Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(
            Icons.local_fire_department_rounded,
            size: 13,
            color: Color(0xFFFF8B94),
          ),
          const SizedBox(width: 2),
          Text(
            _formatPopular(comic.popular!),
            style: TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.w700,
              color: isDark ? Colors.white70 : const Color(0xFF6B7280),
            ),
          ),
        ],
      );
    }
    return const SizedBox.shrink();
  }

  static String _formatPopular(int popular) {
    if (popular >= 10000) {
      return '${(popular / 10000).toStringAsFixed(1)}万';
    }
    return popular.toString();
  }
}
