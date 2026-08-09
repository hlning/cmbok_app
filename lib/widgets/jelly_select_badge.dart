import 'package:flutter/material.dart';
import '../theme/jelly_theme.dart';

/// 多选模式下的圆形勾选角标（选中=主色实心✓，未选=白底空心）
class JellySelectBadge extends StatelessWidget {
  final bool selected;
  final double size;

  const JellySelectBadge({super.key, required this.selected, this.size = 24});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: selected
            ? JellyTheme.primary
            : Colors.white.withValues(alpha: 0.9),
        border: Border.all(
          color: selected ? JellyTheme.primary : Colors.grey,
          width: 2,
        ),
        boxShadow: const [BoxShadow(color: Colors.black26, blurRadius: 4)],
      ),
      child: selected
          ? const Icon(Icons.check, size: 16, color: Colors.white)
          : const SizedBox.shrink(),
    );
  }
}
