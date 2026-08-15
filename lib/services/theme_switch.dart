import 'dart:ui' show Offset;

/// 主题切换圆形扩散动画的起点暂存（仅运行时，不持久化）。
/// 暗色模式图标按钮点击时写入图标中心屏幕坐标（逻辑像素），
/// MyApp 在播放扩散动画时读取并清空；缺省时回退屏幕中心。
class ThemeSwitch {
  ThemeSwitch._();
  static Offset? origin;
}
