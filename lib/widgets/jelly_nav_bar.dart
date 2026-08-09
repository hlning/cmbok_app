import 'package:flutter/material.dart';
import '../services/settings_service.dart';
import '../theme/jelly_theme.dart';

/// 果冻风格底部导航栏（支持悬浮胶囊样式，果冻弹性指示器）
class JellyNavBar extends StatefulWidget {
  final int currentIndex;
  final Function(int) onTap;
  final List<JellyNavItem> items;
  final bool floating;

  const JellyNavBar({
    super.key,
    required this.currentIndex,
    required this.onTap,
    required this.items,
    this.floating = false,
  }) : assert(items.length >= 2 && items.length <= 5);

  /// 悬浮导航栏总占用高度（高度 + 底部外边距），用于页面 FAB 等避让
  static const double floatingTotalHeight =
      floatingBarHeight + floatingBottomMargin;
  static const double floatingBarHeight = 72.0;
  static const double floatingBottomMargin = 30.0;

  /// 内容底部避让高度：悬浮导航栏开启时返回总高+8，否则 0
  static double get contentBottomAvoid =>
      SettingsService().navFloating ? floatingTotalHeight + 8 : 0.0;

  @override
  State<JellyNavBar> createState() => _JellyNavBarState();
}

class _JellyNavBarState extends State<JellyNavBar>
    with SingleTickerProviderStateMixin {
  late AnimationController _controller;
  int _previousIndex = 0;

  // 果冻弹性曲线（直接 transform，避免在 build 中创建 CurvedAnimation 造成监听器泄漏）
  static const _curve = ElasticOutCurve(0.7);

  // 导航栏尺寸：整体加高，底部间距稍高于顶部，左右上角圆角
  static const _barHeight = 80.0; // 整体高度（原 64）
  static const _topPad = 10.0; // 顶部间距
  static const _bottomPad = 18.0; // 底部间距（> 顶部，内容整体偏上）
  static const _topRadius = 20.0; // 左、右上角圆角
  static const _pillPad = 8.0; // 指示器左右内边距
  static const _indicatorRatio = 1.25;

  // 悬浮模式尺寸（高度/边距在 Widget 类中公开定义，供外部避让使用）
  static const _floatingRadius = 32.0; // 悬浮胶囊圆角
  static const _floatingTopPad = 12.0; // 悬浮时上下内边距
  static const _floatingIconSize = 26.0; // 悬浮时图标尺寸
  // 悬浮每项宽度随屏宽自适应（宽屏适当加宽），见 _buildFloatingNavBar
  static const _floatingItemMin = 80.0; // 每项最小宽度（手机保底）
  static const _floatingItemMax = 120.0; // 每项最大宽度（宽屏上限）
  static const _floatingItemFactor = 0.2; // 随屏宽增长系数

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      duration: const Duration(milliseconds: 850), // 切换速度放慢（原 600）
      vsync: this,
    )..value = 1.0; // 初始处于静止态，指示器归位到当前项
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _onItemTap(int index) {
    if (index != widget.currentIndex) {
      _previousIndex = widget.currentIndex;
      _controller.reset();
      _controller.forward();
      widget.onTap(index);
    }
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;

    if (widget.floating) {
      return _buildFloatingNavBar(isDark);
    } else {
      return _buildFixedNavBar(isDark);
    }
  }

  /// 固定底部导航栏（原始样式：贴底、顶部圆角）
  Widget _buildFixedNavBar(bool isDark) {
    return Container(
      decoration: BoxDecoration(
        color: isDark ? const Color(0xFF1A1A2E) : Colors.white,
        borderRadius: const BorderRadius.vertical(
          top: Radius.circular(_topRadius), // 左、右上角圆角
        ),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.05),
            blurRadius: 10,
            offset: const Offset(0, -2),
          ),
        ],
      ),
      child: SafeArea(
        top: false,
        child: SizedBox(
          height: _barHeight, // 整体高度加高
          child: Padding(
            // 底部间距稍高于顶部，内容整体偏上
            padding: const EdgeInsets.only(top: _topPad, bottom: _bottomPad),
            child: _buildNavContent(height: _barHeight - _topPad - _bottomPad),
          ),
        ),
      ),
    );
  }

  /// 悬浮胶囊导航栏（不透明胶囊背景，与搜索框样式一致）
  Widget _buildFloatingNavBar(bool isDark) {
    return SafeArea(
      top: false,
      child: LayoutBuilder(
        builder: (context, constraints) {
          final screenWidth = MediaQuery.of(context).size.width;
          final horizontalMargin = (screenWidth * 0.045).clamp(12.0, 60.0);
          // 每项宽度随屏宽自适应（宽屏加宽，限制在 [min, max]），胶囊宽度 = 每项 × 项数，不超过可用宽度
          final perItem = (screenWidth * _floatingItemFactor).clamp(
            _floatingItemMin,
            _floatingItemMax,
          );
          final contentWidth = (widget.items.length * perItem).clamp(
            0.0,
            constraints.maxWidth,
          );
          // 胶囊居中：在屏幕边距基础上补足左右内边距，垂直结构保持不变（仍贴底部）
          final sidePad = (constraints.maxWidth - contentWidth) / 2;
          return Padding(
            padding: EdgeInsets.fromLTRB(
              horizontalMargin + sidePad,
              0,
              horizontalMargin + sidePad,
              JellyNavBar.floatingBottomMargin,
            ),
            child: Container(
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(_floatingRadius),
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
              child: ClipRRect(
                borderRadius: BorderRadius.circular(_floatingRadius),
                child: BackdropFilter(
                  filter: JellyTheme.glassFilter,
                  child: Container(
                    height: JellyNavBar.floatingBarHeight,
                    decoration: BoxDecoration(
                      color: isDark
                          ? const Color(0xFF2D2D4A).withValues(alpha: 0.8)
                          : Colors.white.withValues(alpha: 0.8),
                      borderRadius: BorderRadius.circular(_floatingRadius),
                    ),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                        vertical: _floatingTopPad,
                      ),
                      child: _buildNavContent(
                        height:
                            JellyNavBar.floatingBarHeight - _floatingTopPad * 2,
                        iconOnly: true,
                        iconSize: _floatingIconSize,
                      ),
                    ),
                  ),
                ),
              ),
            ),
          );
        },
      ),
    );
  }

  /// 导航栏内部内容（弹性指示器 + 导航项），两种模式共用
  Widget _buildNavContent({
    required double height,
    bool iconOnly = false,
    double iconSize = 22.0,
  }) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final itemWidth = constraints.maxWidth / widget.items.length;
        final bandHeight = height;
        final naturalWidth = itemWidth - _pillPad * 2;
        final indicatorWidth = naturalWidth < bandHeight * _indicatorRatio
            ? naturalWidth
            : bandHeight * _indicatorRatio;
        final pillPad = (itemWidth - indicatorWidth) / 2;
        return Stack(
          children: [
            // 果冻背景指示器（弹性滑动 + 弹性缩放）
            AnimatedBuilder(
              animation: _controller,
              builder: (context, _) {
                final progress = _curve.transform(_controller.value);
                final left =
                    _previousIndex * itemWidth +
                    (widget.currentIndex - _previousIndex) *
                        itemWidth *
                        progress;
                final scale = 0.88 + 0.12 * progress;
                final isDark = Theme.of(context).brightness == Brightness.dark;
                return Positioned(
                  top: 0,
                  left: left + pillPad,
                  width: indicatorWidth,
                  height: bandHeight,
                  child: Transform.scale(
                    scale: scale,
                    child: Container(
                      decoration: BoxDecoration(
                        color: isDark
                            ? const Color(0xFF443EB1)
                            : JellyTheme.navSelectedBg,
                        borderRadius: BorderRadius.circular(18),
                      ),
                    ),
                  ),
                );
              },
            ),
            // 导航项（固定宽度，纵向拉伸保证点击区域）
            Positioned.fill(
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: List.generate(widget.items.length, (index) {
                  return SizedBox(
                    width: itemWidth,
                    child: _JellyNavItem(
                      item: widget.items[index],
                      isSelected: index == widget.currentIndex,
                      onTap: () => _onItemTap(index),
                      iconOnly: iconOnly,
                      iconSize: iconSize,
                    ),
                  );
                }),
              ),
            ),
          ],
        );
      },
    );
  }
}

/// 果冻导航项组件
class _JellyNavItem extends StatelessWidget {
  final JellyNavItem item;
  final bool isSelected;
  final VoidCallback onTap;
  final bool iconOnly;
  final double iconSize;

  const _JellyNavItem({
    required this.item,
    required this.isSelected,
    required this.onTap,
    this.iconOnly = false,
    this.iconSize = 22.0,
  });

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final color = isSelected
        ? (isDark ? Colors.white : JellyTheme.navSelectedFg)
        : (isDark ? Colors.white54 : JellyTheme.navUnselected);

    return InkWell(
      onTap: onTap,
      splashColor: Colors.transparent,
      highlightColor: Colors.transparent,
      child: Center(
        child: iconOnly
            ? _buildIcon(color)
            : Column(
                mainAxisSize: MainAxisSize.min,
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  _buildIcon(color),
                  const SizedBox(height: 2),
                  Text(
                    item.label,
                    style: TextStyle(
                      color: color,
                      fontSize: 11,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ],
              ),
      ),
    );
  }

  Widget _buildIcon(Color color) {
    if (item.iconBuilder != null) {
      return item.iconBuilder!(color, iconSize);
    }
    return item.emoji != null
        ? Text(item.emoji!, style: TextStyle(fontSize: iconSize, height: 1.0))
        : Icon(item.icon, color: color, size: iconSize);
  }
}

/// 自定义图标构建器：传入颜色与尺寸，返回图标 Widget（跟随选中态变色）
typedef JellyIconBuilder = Widget Function(Color color, double size);

/// 导航项数据
class JellyNavItem {
  final IconData? icon;
  final String? emoji;
  final JellyIconBuilder? iconBuilder;
  final String label;

  const JellyNavItem({
    this.icon,
    this.emoji,
    this.iconBuilder,
    required this.label,
  }) : assert(icon != null || emoji != null || iconBuilder != null);
}
