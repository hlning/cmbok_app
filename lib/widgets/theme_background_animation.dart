import 'package:flutter/material.dart';

import '../services/settings_service.dart';
import '../theme/jelly_theme.dart';
import '../theme/theme_background_painters.dart';

/// 主题内置背景动画层。
///
/// 按当前主题预设取对应 painter；无内置动画的主题返回空（透出 Scaffold 纯色，
/// 零回归）。用 [RepaintBoundary] 隔离，仅由内部 [AnimationController] 驱动重绘，
/// 不影响上层列表滚动。路由非栈顶时由 [TickerMode] 自动暂停省电。
class ThemeBackgroundAnimation extends StatefulWidget {
  const ThemeBackgroundAnimation({
    super.key,
    this.topInset = 0,
    this.bottomInset = 0,
  });

  /// 顶部留白：顶部动画元素距屏幕顶的高度（避开 pinned AppBar 遮挡）。
  final double topInset;

  /// 底部留白：草丛地面线距屏幕底的高度（避开浮动导航栏等遮挡）。
  final double bottomInset;

  @override
  State<ThemeBackgroundAnimation> createState() =>
      _ThemeBackgroundAnimationState();
}

class _ThemeBackgroundAnimationState extends State<ThemeBackgroundAnimation>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;

  /// 降帧重绘源：[AnimationController] 每帧 notify；开启降帧时仅每 2 帧采样到
  /// [_progress]，painter 监听 [_driven]（代理 [_progress]），重绘频率减半省电。
  late final ValueNotifier<double> _progress;
  late final _DrivenAnimation _driven;
  int _frameTick = 0;

  /// 动画循环周期计数：[AnimationController.repeat] 下 [AnimationController.value]
  /// 每 0~1 完全相同，任何 t 的纯函数都会每周期重复。用回绕检测累加周期号传给
  /// painter 作随机种子偏移，使藤蔓等元素每次萌发位置/形态不同（单次萌发内稳定）。
  int _cycle = 0;
  double _prevValue = 0;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 16),
    );
    _progress = ValueNotifier(_controller.value);
    _driven = _DrivenAnimation(_progress);
    if (SettingsService().backgroundAnimation) _controller.repeat();
    _controller.addListener(_onTick);
    SettingsService().addListener(_onSettingsChanged);
  }

  @override
  void dispose() {
    SettingsService().removeListener(_onSettingsChanged);
    _controller.removeListener(_onTick);
    _controller.dispose();
    _progress.dispose();
    super.dispose();
  }

  /// 检测 value 回绕（~1 -> 0），累加周期号并重建取新种子
  void _onTick() {
    final v = _controller.value;
    if (_prevValue > 0.5 && v < 0.5) {
      _cycle++;
      if (mounted) setState(() {});
    }
    _prevValue = v;
    // 降帧：开启时每 2 帧采样一次（~30fps），painter 重绘频率减半
    if (SettingsService().frameRateReduced) {
      _frameTick++;
      if (_frameTick % 2 != 0) return;
    }
    _progress.value = v;
  }

  /// 主题/暗色模式切换时重建，取新 painter
  void _onSettingsChanged() {
    if (!mounted) return;
    final enabled = SettingsService().backgroundAnimation;
    if (enabled && !_controller.isAnimating) {
      _controller.repeat();
    } else if (!enabled && _controller.isAnimating) {
      _controller.stop();
    }
    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final settings = SettingsService();
    if (!settings.backgroundAnimation) return const SizedBox.shrink();
    final painter = backgroundPainterFor(
      // 自定义主题借用内置动画时取 currentBackground.animationId；内置主题其值即
      // 自身 id；纯色/图片/未知 → 回退 themePreset（custom_* → null → 返回空）。
      settings.currentBackground.animationId ?? settings.themePreset,
      _driven,
      settings.isDarkMode,
      JellyTheme.palette,
      topInset: widget.topInset,
      bottomInset: widget.bottomInset,
      cycle: _cycle,
    );
    if (painter == null) return const SizedBox.shrink();
    return RepaintBoundary(
      child: CustomPaint(painter: painter, child: const SizedBox.expand()),
    );
  }
}

/// 代理 [ValueNotifier] 为 [Animation]，供 painter 作降帧重绘源。
class _DrivenAnimation extends Animation<double> {
  _DrivenAnimation(this._v);

  final ValueNotifier<double> _v;

  @override
  double get value => _v.value;

  @override
  void addListener(VoidCallback listener) => _v.addListener(listener);

  @override
  void removeListener(VoidCallback listener) => _v.removeListener(listener);

  @override
  void addStatusListener(AnimationStatusListener listener) {}

  @override
  void removeStatusListener(AnimationStatusListener listener) {}

  @override
  AnimationStatus get status => AnimationStatus.forward;
}
