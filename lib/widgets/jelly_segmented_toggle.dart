import 'package:flutter/material.dart';
import '../theme/jelly_theme.dart';

/// 分段数据（图标、emoji 或 文字）
class JellySegmentData {
  final IconData? icon;
  final String? emoji;
  final String? label;

  const JellySegmentData({this.icon, this.emoji, this.label});
}

/// 果冻风分段切换控件（滑动指示器跟随 index 1:1，无延迟）
/// 用于搜索页视图切换、收藏页 Tab 等。
class JellySegmentedToggle extends StatelessWidget {
  /// 当前指示器位置（支持小数，用于跟随滑动动画）
  final double index;
  final ValueChanged<int> onChanged;
  final List<JellySegmentData> segments;
  final double segmentWidth;

  const JellySegmentedToggle({
    super.key,
    required this.index,
    required this.onChanged,
    required this.segments,
    this.segmentWidth = 40,
  });

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final selectedColor = isDark ? Colors.white : JellyTheme.navSelectedFg;
    final unselectedColor = isDark ? Colors.white54 : JellyTheme.navUnselected;
    final roundedIndex = index.round();

    return Container(
      width: segmentWidth * segments.length + 10,
      height: 50,
      decoration: BoxDecoration(
        color: isDark ? JellyTheme.cardDark : Colors.white,
        borderRadius: BorderRadius.circular(25),
        boxShadow: [
          BoxShadow(
            color: isDark
                ? JellyTheme.primary.withValues(alpha: 0.15)
                : Colors.black.withValues(alpha: 0.06),
            blurRadius: 12,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 5),
        child: SizedBox(
          width: segmentWidth * segments.length,
          height: 40,
          child: Stack(
            clipBehavior: Clip.none,
            children: [
              // 滑动指示器（跟随 index 1:1，无延迟）
              Positioned(
                left: index * segmentWidth,
                top: 0,
                child: Container(
                  width: segmentWidth,
                  height: 40,
                  decoration: BoxDecoration(
                    color: isDark
                        ? JellyTheme.navSelectedFg
                        : JellyTheme.navSelectedBg,
                    borderRadius: BorderRadius.circular(20),
                  ),
                ),
              ),
              // 分段内容
              Row(
                children: List.generate(segments.length, (i) {
                  final selected = i == roundedIndex;
                  final seg = segments[i];
                  final color = selected ? selectedColor : unselectedColor;
                  return GestureDetector(
                    onTap: () => onChanged(i),
                    behavior: HitTestBehavior.opaque,
                    child: SizedBox(
                      width: segmentWidth,
                      height: 40,
                      child: Center(
                        child: seg.emoji != null
                            ? Text(
                                seg.emoji!,
                                style: const TextStyle(fontSize: 18),
                              )
                            : seg.icon != null
                            ? Icon(seg.icon, size: 20, color: color)
                            : Text(
                                seg.label ?? '',
                                style: TextStyle(
                                  fontSize: 13,
                                  fontWeight: selected
                                      ? FontWeight.w700
                                      : FontWeight.w500,
                                  color: color,
                                ),
                              ),
                      ),
                    ),
                  );
                }),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
