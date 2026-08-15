import 'dart:io';

import 'package:flutter/material.dart';

import '../services/settings_service.dart';
import '../theme/jelly_palette.dart';
import 'theme_background_animation.dart';

/// 主题背景统一入口：按当前主题的背景配置（[SettingsService.currentBackground]）渲染。
///
/// - **图片**：用户上传图片全屏铺满 + 淡遮罩，**独立于面板右上角的「动画」总开关**
///   （图片是静态层，非动画）。
/// - **动画 / 纯色**：委托 [ThemeBackgroundAnimation]——其内部按「动画」总开关与
///   painter 是否存在决定画动画或返回空（SizedBox.shrink）。
///
/// 由 [SettingsService] 驱动重建（主题/暗色切换时刷新）。图片层是静态的，包在
/// [RepaintBoundary] 内，不随上层列表滚动重绘。
class ThemeBackground extends StatelessWidget {
  const ThemeBackground({super.key, this.topInset = 0, this.bottomInset = 0});

  final double topInset;
  final double bottomInset;

  @override
  Widget build(BuildContext context) {
    // 监听设置：切换主题/明暗时即时刷新（图片分支不会自监听，动画分支自身已监听，
    // 套一层 ListenableBuilder 对其无副作用）。
    return ListenableBuilder(
      listenable: SettingsService(),
      builder: (context, _) {
        final settings = SettingsService();
        final cfg = settings.currentBackground;
        if (cfg.type == ThemeBackgroundType.image && cfg.imagePath != null) {
          return RepaintBoundary(
            child: _ThemeImageBackground(
              path: cfg.imagePath!,
              isDark: settings.isDarkMode,
            ),
          );
        }
        return ThemeBackgroundAnimation(
          topInset: topInset,
          bottomInset: bottomInset,
        );
      },
    );
  }
}

/// 图片背景层：`BoxFit.cover` 全屏铺满 + 淡遮罩（保证标题/副标题可读）。
///
/// 按物理像素宽度 `cacheWidth` 下采样解码，限制内存占用（背景无需超清）。
/// 路径文件被手动删除等情况由 [Image.errorBuilder] 降级为空，透出 Scaffold 纯色。
class _ThemeImageBackground extends StatelessWidget {
  const _ThemeImageBackground({required this.path, required this.isDark});

  final String path;
  final bool isDark;

  @override
  Widget build(BuildContext context) {
    final dpr = MediaQuery.devicePixelRatioOf(context);
    final widthPx = (MediaQuery.sizeOf(context).width * dpr).round();
    // 遮罩强度先固定，看效果再调（暗色更深以保证白色文字可读）。
    final scrim = isDark
        ? Colors.black.withValues(alpha: 0.45)
        : Colors.black.withValues(alpha: 0.22);
    return Stack(
      fit: StackFit.expand,
      children: [
        Image.file(
          File(path),
          fit: BoxFit.cover,
          width: double.infinity,
          height: double.infinity,
          cacheWidth: widthPx,
          gaplessPlayback: true,
          errorBuilder: (_, _, _) => const SizedBox.shrink(),
        ),
        IgnorePointer(child: ColoredBox(color: scrim)),
      ],
    );
  }
}
