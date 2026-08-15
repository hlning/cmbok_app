import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'jelly_palette.dart';

/// 「清新护眼」主题背景动画：底部草丛萌发 + 花朵绽放 + 顶部短草/小花 +
/// 飘落花瓣（线条生长风格）。
///
/// 单 [Animation] 驱动；元素按相位错峰萌发、生长后轻摆、末段淡出，循环无突跳。
/// 仅画前景，背景透明（由 Scaffold 纯色兜底）。纯 [Path] 绘制（无 saveLayer/clipPath），
/// 元素稀疏，保证 60fps。
class GreenGrowthPainter extends CustomPainter {
  GreenGrowthPainter({
    required this.animation,
    required this.isDark,
    required this.palette,
    this.topInset = 0,
    this.bottomInset = 0,
  }) : super(repaint: animation);

  final Animation<double> animation;
  final bool isDark;
  final JellyPalette palette;

  /// 顶部留白：顶部草丛/小花距屏幕顶的高度（避开 pinned AppBar 遮挡）。
  final double topInset;

  /// 底部留白：草丛地面线距屏幕底的高度（避开浮动导航栏等遮挡）。
  final double bottomInset;

  @override
  void paint(Canvas canvas, Size size) {
    final t = animation.value;
    final w = size.width;
    final h = size.height;
    if (w <= 0 || h <= 0) return;

    final groundY = h - bottomInset; // 底部地面线

    // 取色（随当前调色板；暗色提亮、降饱和）
    final grassMain = (isDark ? palette.primaryLight : palette.primaryDark)
        .withValues(alpha: isDark ? 0.55 : 0.5);
    final grassSub = (isDark ? palette.success : palette.primary).withValues(
      alpha: isDark ? 0.45 : 0.42,
    );
    final topGrassC = (isDark ? palette.primaryLight : palette.primary)
        .withValues(alpha: isDark ? 0.4 : 0.38);
    final petalC = palette.accent.withValues(alpha: isDark ? 0.7 : 0.82);
    final coreC = palette.warning.withValues(alpha: isDark ? 0.85 : 0.9);
    final fallC = palette.accent.withValues(alpha: isDark ? 0.5 : 0.55);

    final grassPaint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round
      ..strokeWidth = 2.2
      ..color = grassMain;
    final grassPaint2 = Paint()
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round
      ..strokeWidth = 1.7
      ..color = grassSub;
    final topGrassPaint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round
      ..strokeWidth = 1.5
      ..color = topGrassC;
    final petalPaint = Paint()
      ..style = PaintingStyle.fill
      ..color = petalC;
    final corePaint = Paint()
      ..style = PaintingStyle.fill
      ..color = coreC;
    final fallPaint = Paint()
      ..style = PaintingStyle.fill
      ..color = fallC;

    // === 底部草丛 ===
    final grassCount = math.max(4, (w / 52).floor());
    for (var i = 0; i < grassCount; i++) {
      final phase = (t + i * 0.06) % 1.0;
      final grow = _easeOut(_clamp01(phase * 3));
      final fade = phase < 0.12
          ? phase / 0.12
          : (phase < 0.82 ? 1.0 : 1 - (phase - 0.82) / 0.18);
      if (grow <= 0 || fade <= 0) continue;
      final baseX = ((i + 0.5) + _noise(i * 73 + 41) * 0.45) * w / grassCount;
      final maxH =
          55.0 + (_noise(i * 137 + 7) * 0.5 + 0.5) * 145; // 55~200，随机参差
      final bladeH = maxH * grow;
      final angle = _noise(i * 211 + 3) * 0.35; // 固定倾角 ±20°，直接歪着
      final dx = math.sin(angle);
      final dy = -math.cos(angle);
      final tipX = baseX + dx * bladeH;
      final tipY = groundY + dy * bladeH;
      final cpX = baseX + dx * bladeH * 0.5 - dy * 4; // 中点+垂直弧度
      final cpY = groundY + dy * bladeH * 0.5 + dx * 4;
      final path = Path()
        ..moveTo(baseX, groundY)
        ..quadraticBezierTo(cpX, cpY, tipX, tipY);
      canvas.drawPath(
        path,
        _withAlpha(i % 2 == 0 ? grassPaint : grassPaint2, fade),
      );
    }

    // === 底部花朵 ===
    final flowerCount = math.max(5, (w / 70).floor() - 1); // 少 1 朵
    for (var i = 0; i < flowerCount; i++) {
      final phase = (t + 0.25 + i * 0.14) % 1.0;
      final bloom = _easeOut(_clamp01(phase * 2.4));
      final fade = phase < 0.12
          ? phase / 0.12
          : (phase < 0.85 ? 1.0 : 1 - (phase - 0.85) / 0.15);
      if (bloom <= 0 || fade <= 0) continue;
      final cx = (i + 0.5) * w / flowerCount + _noise(i + 50) * 22;
      final cy =
          groundY -
          (35 + (_noise(i * 89 + 13) * 0.5 + 0.5) * 165); // 离地 35~200，随机分散
      final breathe = 1 + math.sin(t * math.pi * 4 + i) * 0.05;
      final r = 6.5 * bloom * breathe;
      _drawFlower(canvas, cx, cy, r, t, petalPaint, corePaint, fade);
    }

    // === 顶部短草（从顶向下垂，高度低）===
    final topCount = math.max(4, (w / 110).floor());
    for (var i = 0; i < topCount; i++) {
      final phase = (t + 0.5 + i * 0.16) % 1.0;
      final grow = _easeOut(_clamp01(phase * 3));
      final fade = phase < 0.12
          ? phase / 0.12
          : (phase < 0.82 ? 1.0 : 1 - (phase - 0.82) / 0.18);
      if (grow <= 0 || fade <= 0) continue;
      final baseX = (i + 0.5) * w / topCount + _noise(i + 100) * 18;
      final bladeCount = 1 + (i % 2); // 1~2 叶
      for (var b = 0; b < bladeCount; b++) {
        final maxH = 14.0 + (i * 5 + b * 3) % 12; // 14~26，矮
        final bladeH = maxH * grow;
        final sway = math.sin(t * math.pi * 2 + i + b) * 3 * grow;
        final lean = (b - (bladeCount - 1) / 2) * 2.5;
        final startX = baseX + lean;
        final tipX = baseX + lean + sway;
        final tipY = topInset + bladeH; // 从 topInset 向下
        final cpX = baseX + lean + sway * 0.4;
        final cpY = topInset + bladeH * 0.5;
        final path = Path()
          ..moveTo(startX, topInset)
          ..quadraticBezierTo(cpX, cpY, tipX, tipY);
        canvas.drawPath(path, _withAlpha(topGrassPaint, fade));
      }
    }

    // === 顶部小花点缀（贴顶，矮）===
    final topFlowerCount = math.max(3, topCount ~/ 2);
    for (var i = 0; i < topFlowerCount; i++) {
      final phase = (t + 0.7 + i * 0.3) % 1.0;
      final bloom = _easeOut(_clamp01(phase * 2.4));
      final fade = phase < 0.12
          ? phase / 0.12
          : (phase < 0.85 ? 1.0 : 1 - (phase - 0.85) / 0.15);
      if (bloom <= 0 || fade <= 0) continue;
      final cx = (i + 0.5) * w / topFlowerCount + _noise(i + 150) * 20;
      final cy = topInset + 16 + bloom * 4; // 贴 AppBar 下沿
      final r = 4.0 * bloom;
      _drawFlower(canvas, cx, cy, r, t, petalPaint, corePaint, fade * 0.85);
    }

    // === 飘落花瓣 ===
    // fallT 系数 1（与全局周期同频）：全局 t 回绕时 fallT 连续不跳；
    // alpha 用 sin² 包络，回绕点 α≈0，垂直回绕（底->顶）不可见。
    const fallCount = 4;
    for (var i = 0; i < fallCount; i++) {
      final fallT = (t + i * 0.27) % 1.0;
      final alpha = _sin2(math.pi * fallT);
      if (alpha <= 0.01) continue;
      final baseX = (i + 0.5) * w / fallCount + _noise(i + 200) * 40;
      final px = baseX + math.sin(t * math.pi * 2 + i * 1.3) * 25;
      final py = fallT * h;
      canvas.save();
      canvas.translate(px, py);
      canvas.rotate(t * math.pi * 2 + i);
      canvas.drawOval(
        Rect.fromCenter(center: Offset.zero, width: 6, height: 9),
        _withAlpha(fallPaint, alpha),
      );
      canvas.restore();
    }
  }

  /// 画一朵 5 瓣花 + 花心
  void _drawFlower(
    Canvas canvas,
    double cx,
    double cy,
    double r,
    double t,
    Paint petalPaint,
    Paint corePaint,
    double fade,
  ) {
    for (var p = 0; p < 5; p++) {
      final ang = p * math.pi * 2 / 5 + t * 0.3;
      canvas.save();
      canvas.translate(cx, cy);
      canvas.rotate(ang);
      final petal = Path()
        ..moveTo(0, 0)
        ..quadraticBezierTo(r * 0.7, -r * 0.6, 0, -r * 1.5)
        ..quadraticBezierTo(-r * 0.7, -r * 0.6, 0, 0);
      canvas.drawPath(petal, _withAlpha(petalPaint, fade));
      canvas.restore();
    }
    canvas.drawCircle(Offset(cx, cy), r * 0.42, _withAlpha(corePaint, fade));
  }

  /// sin² 包络：x=0/π 时为 0，用于让元素在相位回绕点（α≈0）不可见。
  static double _sin2(double x) {
    final s = math.sin(x);
    return s * s;
  }

  /// 确定性伪随机：LCG 长周期，分布均匀。
  /// （旧 `seed*127.1` 系数因 .1 小数导致周期仅 10，高度趋同）
  static double _noise(int seed) {
    return ((seed * 9301 + 49297) % 233280) / 233280.0 * 2 - 1;
  }

  static double _clamp01(double v) => v < 0 ? 0 : (v > 1 ? 1 : v);
  static double _easeOut(double t) => 1 - (1 - t) * (1 - t);

  static Paint _withAlpha(Paint src, double fade) {
    return Paint()
      ..style = src.style
      ..strokeCap = src.strokeCap
      ..strokeWidth = src.strokeWidth
      ..color = src.color.withValues(alpha: src.color.a * fade);
  }

  @override
  bool shouldRepaint(covariant GreenGrowthPainter old) =>
      animation != old.animation ||
      isDark != old.isDark ||
      palette != old.palette ||
      topInset != old.topInset ||
      bottomInset != old.bottomInset;
}

/// 「魅力紫色」主题背景动画：顶部藤蔓星花萌发 + 星点闪烁明灭 +
/// 星形光点旋转飘落 + 底部萤火光点上浮（梦幻星夜风格）。
///
/// 单 [Animation] 驱动；元素按相位错峰萌发、生长后轻摆/呼吸、末段淡出，循环无突跳。
/// 仅画前景，背景透明（由 Scaffold 纯色兜底）。纯 [Path] 绘制（无 saveLayer/clipPath），
/// 元素稀疏，保证 60fps。
class JellyStarryNightPainter extends CustomPainter {
  JellyStarryNightPainter({
    required this.animation,
    required this.isDark,
    required this.palette,
    this.topInset = 0,
    this.bottomInset = 0,
    this.cycle = 0,
  }) : super(repaint: animation);

  final Animation<double> animation;
  final bool isDark;
  final JellyPalette palette;

  /// 顶部留白：藤蔓星花距屏幕顶的高度（避开 pinned AppBar 遮挡）。
  final double topInset;

  /// 底部留白：萤火上浮起点距屏幕底的高度（避开浮动导航栏等遮挡）。
  final double bottomInset;

  /// 动画周期计数：作随机种子偏移，使藤蔓每次萌发位置/形态不同。
  final int cycle;

  @override
  void paint(Canvas canvas, Size size) {
    final t = animation.value;
    final w = size.width;
    final h = size.height;
    if (w <= 0 || h <= 0) return;

    final groundY = h - bottomInset; // 萤火上浮起点

    // 取色（随当前调色板；暗色提亮、降饱和）
    final vineC = (isDark ? palette.primaryLight : palette.primaryDark)
        .withValues(alpha: isDark ? 0.5 : 0.45);
    final starC = (isDark ? palette.primaryLight : palette.primary).withValues(
      alpha: isDark ? 0.85 : 0.7,
    );
    final petalC = palette.accent.withValues(alpha: isDark ? 0.7 : 0.82);
    final coreC = palette.warning.withValues(alpha: isDark ? 0.85 : 0.9);
    final fireflyC = palette.warning.withValues(alpha: isDark ? 0.75 : 0.68);
    final fireflyGlowC = palette.warning.withValues(alpha: isDark ? 0.25 : 0.2);

    final vinePaint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round
      ..strokeWidth = 1.8
      ..color = vineC;
    final starPaint = Paint()
      ..style = PaintingStyle.fill
      ..color = starC;
    final petalPaint = Paint()
      ..style = PaintingStyle.fill
      ..color = petalC;
    final corePaint = Paint()
      ..style = PaintingStyle.fill
      ..color = coreC;
    final fireflyPaint = Paint()
      ..style = PaintingStyle.fill
      ..color = fireflyC;
    final fireflyGlowPaint = Paint()
      ..style = PaintingStyle.fill
      ..color = fireflyGlowC;

    // === 星点闪烁（稀疏，全屏散布）===
    final starCount = math.max(20, (w * h / 18000).floor());
    for (var i = 0; i < starCount; i++) {
      final phase = (t + i * 0.13) % 1.0;
      final twinkle = 0.25 + 0.75 * (0.5 + 0.5 * math.sin(phase * math.pi * 3));
      if (twinkle <= 0.05) continue;
      final x = (_noise(i * 73 + 11) * 0.5 + 0.5) * w;
      final y = (_noise(i * 137 + 5) * 0.5 + 0.5) * h;
      final r = 0.8 + (_noise(i * 211) * 0.5 + 0.5) * 1.0; // 0.8~1.8
      canvas.drawCircle(Offset(x, y), r, _withAlpha(starPaint, twinkle));
    }

    // === 顶部藤蔓星花萌发（直直向下生长，末端星花绽放）===
    final vineCount = math.max(3, (w / 150).floor());
    for (var i = 0; i < vineCount; i++) {
      final phase = (t + i * 0.18) % 1.0;
      final grow = _easeOut(_clamp01(phase * 2.5));
      final fade = _sin2(math.pi * phase);
      if (grow <= 0 || fade <= 0.01) continue;
      // 萌发轮次：仅在自己重新萌发（phase 回绕、grow≈0 不可见）时换种子，
      // 正在生长/显示的藤蔓轮次稳定，不被全局周期回绕打断。
      final round = cycle + (t + i * 0.18).floor();
      final c = round * 1009;
      final slotW = w / vineCount;
      final baseX = (i + 0.5) * slotW + _noise(i + 30 + c) * slotW * 0.8;
      // 高度更随机：混合两段独立噪声打破相邻规律，范围 10~75
      final hN =
          (_noise(i * 89 + 13 + c) * 0.5 + 0.5) * 0.6 +
          (_noise(i * 211 + 37 + c * 7) * 0.5 + 0.5) * 0.4;
      final maxLen = 10.0 + hN * 65;
      final len = maxLen * grow;
      // 自然弧度生长：每根藤蔓固定弯曲方向/幅度（不随时间摆动）
      final bend = _noise(i * 53 + 7 + c) * len * 0.5;
      final tipX = baseX + bend * 0.4;
      final tipY = topInset + len;
      final path = Path()
        ..moveTo(baseX, topInset)
        ..quadraticBezierTo(baseX + bend, topInset + len * 0.5, tipX, tipY);
      canvas.drawPath(path, _withAlpha(vinePaint, fade));
      // 末端星花：生长过半后绽放
      final bloom = _easeOut(_clamp01((phase - 0.4) * 3));
      if (bloom > 0) {
        final breathe = 1 + math.sin(t * math.pi * 4 + i) * 0.06;
        final r = 5.0 * bloom * breathe;
        _drawStarFlower(canvas, tipX, tipY, r, t, petalPaint, corePaint, fade);
      }
    }

    // === 底部萤火光点上浮 ===
    // phase 系数 1（与全局周期同频）：全局 t 回绕时 phase 连续不跳；
    // fade 用 sin² 包络，回绕点 α≈0，上浮回绕（顶->底）不可见。
    const fireflyCount = 8;
    for (var i = 0; i < fireflyCount; i++) {
      final phase = (t + i * 0.2) % 1.0;
      final rise = _easeOut(_clamp01(phase * 1.3));
      final fade = _sin2(math.pi * phase);
      if (fade <= 0.01) continue;
      final baseX = (i + 0.5) * w / fireflyCount + _noise(i + 250) * 50;
      final px = baseX + math.sin(t * math.pi * 2 + i * 2) * 8;
      final riseH = 80.0 + (_noise(i * 55) * 0.5 + 0.5) * 70; // 80~150
      final py = groundY - rise * riseH;
      final glow =
          0.35 + 0.65 * (0.5 + 0.5 * math.sin(phase * math.pi * 2 + i));
      final r = 1.8 + (_noise(i * 17) * 0.5 + 0.5) * 1.2; // 1.8~3.0
      // 外圈柔光 + 核心光点
      canvas.drawCircle(
        Offset(px, py),
        r * 2.6,
        _withAlpha(fireflyGlowPaint, fade * glow),
      );
      canvas.drawCircle(
        Offset(px, py),
        r,
        _withAlpha(fireflyPaint, fade * glow),
      );
    }

    // === 顶部萤火光点下飘 ===
    const topFireflyCount = 4;
    for (var i = 0; i < topFireflyCount; i++) {
      final phase = (t + i * 0.27 + 0.13) % 1.0;
      final fall = _easeOut(_clamp01(phase * 1.3));
      final fade = _sin2(math.pi * phase);
      if (fade <= 0.01) continue;
      final baseX = (i + 0.5) * w / topFireflyCount + _noise(i + 310) * 50;
      final px = baseX + math.sin(t * math.pi * 2 + i * 2 + 1) * 8;
      final fallH = 70.0 + (_noise(i * 61 + 9) * 0.5 + 0.5) * 60; // 70~130
      final py = topInset + fall * fallH;
      final glow =
          0.35 + 0.65 * (0.5 + 0.5 * math.sin(phase * math.pi * 2 + i + 1));
      final r = 1.8 + (_noise(i * 19 + 3) * 0.5 + 0.5) * 1.2; // 1.8~3.0
      // 外圈柔光 + 核心光点
      canvas.drawCircle(
        Offset(px, py),
        r * 2.6,
        _withAlpha(fireflyGlowPaint, fade * glow),
      );
      canvas.drawCircle(
        Offset(px, py),
        r,
        _withAlpha(fireflyPaint, fade * glow),
      );
    }
  }

  /// 画一朵 5 瓣星花（瓣更尖长）+ 花心
  void _drawStarFlower(
    Canvas canvas,
    double cx,
    double cy,
    double r,
    double t,
    Paint petalPaint,
    Paint corePaint,
    double fade,
  ) {
    for (var p = 0; p < 5; p++) {
      final ang = p * math.pi * 2 / 5 + t * 0.3;
      canvas.save();
      canvas.translate(cx, cy);
      canvas.rotate(ang);
      final petal = Path()
        ..moveTo(0, 0)
        ..quadraticBezierTo(r * 0.45, -r * 0.35, 0, -r * 1.9)
        ..quadraticBezierTo(-r * 0.45, -r * 0.35, 0, 0);
      canvas.drawPath(petal, _withAlpha(petalPaint, fade));
      canvas.restore();
    }
    canvas.drawCircle(Offset(cx, cy), r * 0.35, _withAlpha(corePaint, fade));
  }

  /// sin² 包络：x=0/π 时为 0，用于让元素在相位回绕点（α≈0）不可见。
  static double _sin2(double x) {
    final s = math.sin(x);
    return s * s;
  }

  /// 确定性伪随机：LCG 长周期，分布均匀（同 GreenGrowthPainter）。
  static double _noise(int seed) {
    return ((seed * 9301 + 49297) % 233280) / 233280.0 * 2 - 1;
  }

  static double _clamp01(double v) => v < 0 ? 0 : (v > 1 ? 1 : v);
  static double _easeOut(double t) => 1 - (1 - t) * (1 - t);

  static Paint _withAlpha(Paint src, double fade) {
    return Paint()
      ..style = src.style
      ..strokeCap = src.strokeCap
      ..strokeWidth = src.strokeWidth
      ..color = src.color.withValues(alpha: src.color.a * fade);
  }

  @override
  bool shouldRepaint(covariant JellyStarryNightPainter old) =>
      animation != old.animation ||
      isDark != old.isDark ||
      palette != old.palette ||
      topInset != old.topInset ||
      bottomInset != old.bottomInset ||
      cycle != old.cycle;
}

/// 「粉色少女」主题背景动画：樱花花瓣旋转飘落 + 中上部樱花绽放呼吸 +
/// 底部柔光泡泡缓缓上浮（柔美日系少女风）。
///
/// 单 [Animation] 驱动。**循环无缝设计**：所有元素相位系数取整数（与全局
/// 周期同频），全局 `t` 回绕（1→0）时 `phase = (t + offset) % 1` 严格连续不跳；
/// 透明度用 `sin²(π·phase)` 包络（两端为 0），元素自身相位回绕时 α≈0，
/// 位置/旋转/大小的残余跳变不可见；花瓣自旋取相位整数圈、摆动取 `2π` 整数倍，
/// 回绕处无视觉突变。仅画前景，背景透明（由 Scaffold 纯色兜底）。
/// 纯 [Path] 绘制（无 saveLayer/clipPath），元素稀疏，保证 60fps。
class SakuraPainter extends CustomPainter {
  SakuraPainter({
    required this.animation,
    required this.isDark,
    required this.palette,
    this.topInset = 0,
    this.bottomInset = 0,
  }) : super(repaint: animation);

  final Animation<double> animation;
  final bool isDark;
  final JellyPalette palette;

  /// 顶部留白：飘落花瓣生成区距屏幕顶的高度（避开 pinned AppBar 遮挡）。
  final double topInset;

  /// 底部留白：泡泡上浮起点距屏幕底的高度（避开浮动导航栏等遮挡）。
  final double bottomInset;

  @override
  void paint(Canvas canvas, Size size) {
    final t = animation.value;
    final w = size.width;
    final h = size.height;
    if (w <= 0 || h <= 0) return;

    final groundY = h - bottomInset; // 泡泡上浮起点
    final span = h - topInset; // 花瓣下落可用高度

    // 取色（随当前调色板；暗色提亮、降饱和）
    final petalC = (isDark ? palette.primaryLight : palette.primary).withValues(
      alpha: isDark ? 0.82 : 0.78,
    );
    final petalAccentC = palette.accent.withValues(alpha: isDark ? 0.78 : 0.72);
    final coreC = palette.warning.withValues(alpha: isDark ? 0.85 : 0.9);
    final bubbleC = (isDark ? palette.primaryLight : palette.primary)
        .withValues(alpha: isDark ? 0.3 : 0.24);
    final bubbleGlowC = (isDark ? palette.accent : palette.primaryLight)
        .withValues(alpha: isDark ? 0.2 : 0.15);
    final highlightC = Colors.white.withValues(alpha: isDark ? 0.45 : 0.5);

    final petalPaint = Paint()
      ..style = PaintingStyle.fill
      ..color = petalC;
    final petalAccentPaint = Paint()
      ..style = PaintingStyle.fill
      ..color = petalAccentC;
    final corePaint = Paint()
      ..style = PaintingStyle.fill
      ..color = coreC;
    final bubblePaint = Paint()
      ..style = PaintingStyle.fill
      ..color = bubbleC;
    final bubbleGlowPaint = Paint()
      ..style = PaintingStyle.fill
      ..color = bubbleGlowC;
    final highlightPaint = Paint()
      ..style = PaintingStyle.fill
      ..color = highlightC;

    // === 樱花花瓣旋转飘落（主层）===
    // phase 系数 1（与全局周期同频）：全局 t 回绕时 phase 连续不跳。
    // py 仅走 70% 屏高以降速（无缝约束下整数系数最慢 16s/全程，缩程=降速，
    // 降帧掉帧时位移更小更顺）。py 相位前移 0.1：花瓣从屏幕外（顶上方）飘入，
    // 在顶部边缘现身并下飘——像草/藤蔓那样"从屏幕顶部出来"，而非中段淡入；
    // sin² 包络保证回绕点 α≈0 无缝。下半屏由泡泡覆盖。
    const fallCount = 7;
    for (var i = 0; i < fallCount; i++) {
      final phase = (t + i * 0.16) % 1.0;
      final fade = _sin2(math.pi * phase); // 两端 0，回绕点不可见
      if (fade <= 0.01) continue;
      final slotW = w / fallCount;
      final baseX = (i + 0.5) * slotW + _noise(i * 73 + 11) * slotW * 0.7;
      final px = baseX + math.sin(t * math.pi * 2 + i * 1.3) * 22;
      final py = topInset + (phase - 0.1) * span * 0.7;
      final r = 5.0 + (_noise(i * 137 + 5) * 0.5 + 0.5) * 3.0; // 5~8
      // 自旋基于 phase（整数圈 2 圈）：phase 回绕整圈跳变 + α≈0，不可见
      final spin = phase * math.pi * 2 * 2 + i * 0.7;
      final paint = i % 2 == 0 ? petalPaint : petalAccentPaint;
      canvas.save();
      canvas.translate(px, py);
      canvas.rotate(spin);
      _drawPetal(canvas, r, _withAlpha(paint, fade));
      canvas.restore();
    }

    // === 中上部樱花绽放呼吸（点缀）===
    const bloomCount = 3;
    for (var i = 0; i < bloomCount; i++) {
      final phase = (t + 0.3 + i * 0.4) % 1.0;
      final fade = _sin2(math.pi * phase);
      if (fade <= 0.01) continue;
      final bloom = _easeOut(_clamp01(phase * 2.2));
      final cx = (i + 1) * w / 4 + _noise(i * 89 + 7) * 30;
      final cy = topInset + span * 0.22 + _noise(i * 53 + 3) * span * 0.18;
      final breathe = 1 + math.sin(t * math.pi * 4 + i) * 0.06;
      final r = 6.5 * bloom * breathe;
      final paint = i % 2 == 0 ? petalPaint : petalAccentPaint;
      _drawSakuraFlower(canvas, cx, cy, r, paint, corePaint, fade);
    }

    // === 底部柔光泡泡缓缓上浮（辅层）===
    const bubbleCount = 6;
    for (var i = 0; i < bubbleCount; i++) {
      final phase = (t + i * 0.16 + 0.1) % 1.0;
      final fade = _sin2(math.pi * phase);
      if (fade <= 0.01) continue;
      final rise = _easeOut(_clamp01(phase * 1.2));
      final baseX = (i + 0.5) * w / bubbleCount + _noise(i * 41 + 5) * 40;
      final px = baseX + math.sin(t * math.pi * 2 + i * 2) * 10;
      final riseH = 120.0 + (_noise(i * 29) * 0.5 + 0.5) * 90; // 120~210
      final py = groundY - rise * riseH;
      final breathe = 1 + math.sin(t * math.pi * 2 + i) * 0.05;
      final r = (4.0 + (_noise(i * 17 + 2) * 0.5 + 0.5) * 5.0) * breathe; // 4~9
      // 外圈柔光 + 半透球体 + 左上高光
      canvas.drawCircle(
        Offset(px, py),
        r * 1.5,
        _withAlpha(bubbleGlowPaint, fade),
      );
      canvas.drawCircle(Offset(px, py), r, _withAlpha(bubblePaint, fade));
      canvas.drawCircle(
        Offset(px - r * 0.32, py - r * 0.32),
        r * 0.28,
        _withAlpha(highlightPaint, fade),
      );
    }
  }

  /// 画单片樱花瓣（顶端带 V 形缺口，原点在瓣中部，瓣尖朝 -y）。
  void _drawPetal(Canvas canvas, double r, Paint paint) {
    final path = Path()
      ..moveTo(0, 0.8 * r)
      ..quadraticBezierTo(0.72 * r, 0.25 * r, 0.28 * r, -0.8 * r)
      ..quadraticBezierTo(0.1 * r, -0.5 * r, 0, -0.45 * r)
      ..quadraticBezierTo(-0.1 * r, -0.5 * r, -0.28 * r, -0.8 * r)
      ..quadraticBezierTo(-0.72 * r, 0.25 * r, 0, 0.8 * r);
    canvas.drawPath(path, paint);
  }

  /// 画一朵 5 瓣樱花（瓣带 V 缺）+ 花心；仅呼吸缩放，不旋转（避免回绕跳变）。
  void _drawSakuraFlower(
    Canvas canvas,
    double cx,
    double cy,
    double r,
    Paint petalPaint,
    Paint corePaint,
    double fade,
  ) {
    for (var p = 0; p < 5; p++) {
      final ang = p * math.pi * 2 / 5;
      canvas.save();
      canvas.translate(cx, cy);
      canvas.rotate(ang);
      canvas.translate(0, -r * 0.5); // 瓣中心外移，瓣底叠于花心
      _drawPetal(canvas, r * 0.8, _withAlpha(petalPaint, fade));
      canvas.restore();
    }
    canvas.drawCircle(Offset(cx, cy), r * 0.4, _withAlpha(corePaint, fade));
  }

  /// sin² 包络：x=0/π 时为 0，用于让元素在相位回绕点（α≈0）不可见。
  static double _sin2(double x) {
    final s = math.sin(x);
    return s * s;
  }

  /// 确定性伪随机：LCG 长周期，分布均匀（同 GreenGrowthPainter）。
  static double _noise(int seed) {
    return ((seed * 9301 + 49297) % 233280) / 233280.0 * 2 - 1;
  }

  static double _clamp01(double v) => v < 0 ? 0 : (v > 1 ? 1 : v);
  static double _easeOut(double t) => 1 - (1 - t) * (1 - t);

  static Paint _withAlpha(Paint src, double fade) {
    return Paint()
      ..style = src.style
      ..strokeCap = src.strokeCap
      ..strokeWidth = src.strokeWidth
      ..color = src.color.withValues(alpha: src.color.a * fade);
  }

  @override
  bool shouldRepaint(covariant SakuraPainter old) =>
      animation != old.animation ||
      isDark != old.isDark ||
      palette != old.palette ||
      topInset != old.topInset ||
      bottomInset != old.bottomInset;
}

/// 「蓝色海洋」主题背景动画：底部多层海浪涌动 + 气泡缓缓上浮 +
/// 底部水草轻摆（静谧海底风格）。
///
/// 单 [Animation] 驱动。**循环无缝设计**：海浪为正弦函数水平滚动，单周期内滚动
/// 整数个波长（[OceanPainter._drawWaveBand] 的 `cyclesPerPeriod`），t 回绕（1→0）
/// 时波形严格相同；气泡/水草相位系数取整数（与全局周期同频），透明度用
/// `sin²(π·phase)` 包络（两端为 0），回绕点 α≈0 不可见；水草摆动取 `2π` 整数倍，
/// 回绕处无突变。仅画前景，背景透明（由 Scaffold 纯色兜底）。纯 [Path] 绘制
/// （无 saveLayer/clipPath），元素稀疏，保证 60fps。
class OceanPainter extends CustomPainter {
  OceanPainter({
    required this.animation,
    required this.isDark,
    required this.palette,
    this.topInset = 0,
    this.bottomInset = 0,
  }) : super(repaint: animation);

  final Animation<double> animation;
  final bool isDark;
  final JellyPalette palette;

  /// 顶部留白：气泡上浮终点距屏幕顶的高度（避开 pinned AppBar 遮挡）。
  final double topInset;

  /// 底部留白：海浪/水草基准线距屏幕底的高度（避开浮动导航栏等遮挡）。
  final double bottomInset;

  @override
  void paint(Canvas canvas, Size size) {
    final t = animation.value;
    final w = size.width;
    final h = size.height;
    if (w <= 0 || h <= 0) return;

    final groundY = h - bottomInset; // 海浪/水草基准线

    // 取色（随当前调色板；暗色提亮、降饱和）
    final waveDeepC = (isDark ? palette.primary : palette.primaryDark)
        .withValues(alpha: isDark ? 0.34 : 0.30);
    final waveMidC = (isDark ? palette.primaryLight : palette.primary)
        .withValues(alpha: isDark ? 0.26 : 0.22);
    final waveShallowC = palette.primaryLight.withValues(
      alpha: isDark ? 0.20 : 0.16,
    );
    final weedC = palette.success.withValues(alpha: isDark ? 0.50 : 0.45);
    final bubbleC = palette.primaryLight.withValues(
      alpha: isDark ? 0.34 : 0.28,
    );
    final bubbleGlowC = palette.primaryLight.withValues(
      alpha: isDark ? 0.20 : 0.16,
    );
    final highlightC = Colors.white.withValues(alpha: isDark ? 0.50 : 0.55);

    final waveDeepPaint = Paint()
      ..style = PaintingStyle.fill
      ..color = waveDeepC;
    final waveMidPaint = Paint()
      ..style = PaintingStyle.fill
      ..color = waveMidC;
    final waveShallowPaint = Paint()
      ..style = PaintingStyle.fill
      ..color = waveShallowC;
    final weedPaint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round
      ..strokeWidth = 2.0
      ..color = weedC;
    final bubblePaint = Paint()
      ..style = PaintingStyle.fill
      ..color = bubbleC;
    final bubbleGlowPaint = Paint()
      ..style = PaintingStyle.fill
      ..color = bubbleGlowC;
    final highlightPaint = Paint()
      ..style = PaintingStyle.fill
      ..color = highlightC;

    // === 底部多层海浪（正弦水平滚动，单周期整数波长→无缝）===
    // 自后向前画三层：浅(远)→中→深(近)，逐层下移、振幅/波长各异，叠出水面层次。
    _drawWaveBand(canvas, w, h, groundY - 26, 14, 120, 2, t, waveShallowPaint);
    _drawWaveBand(canvas, w, h, groundY - 10, 18, 165, 3, t, waveMidPaint);
    _drawWaveBand(canvas, w, h, groundY + 6, 12, 85, 4, t, waveDeepPaint);

    // === 底部水草轻摆（从海浪中萌发，缓慢摇摆）===
    final weedCount = math.max(3, (w / 130).floor());
    for (var i = 0; i < weedCount; i++) {
      final phase = (t + i * 0.21) % 1.0;
      final grow = _easeOut(_clamp01(phase * 2.2));
      final fade = _sin2(math.pi * phase);
      if (grow <= 0 || fade <= 0.01) continue;
      final baseX = (i + 0.5) * w / weedCount + _noise(i * 73 + 11) * 28;
      final maxH = 42.0 + (_noise(i * 137 + 5) * 0.5 + 0.5) * 80; // 42~122
      final len = maxH * grow;
      // 摇摆：sin(2π·t) 整数圈，回绕处无突变；i 错峰相位
      final sway = math.sin(t * math.pi * 2 + i * 1.3) * 14 * grow;
      final tipX = baseX + sway;
      final tipY = groundY - 4 - len;
      // 中点带固定弧度（藤蔓式自然弯曲，不随时间抖动）
      final cpX = baseX + sway * 0.5 + _noise(i * 53 + 7) * 8;
      final cpY = groundY - 4 - len * 0.5;
      final path = Path()
        ..moveTo(baseX, groundY - 4)
        ..quadraticBezierTo(cpX, cpY, tipX, tipY);
      canvas.drawPath(path, _withAlpha(weedPaint, fade));
    }

    // === 气泡缓缓上浮（sin² 包络，回绕点 α≈0 不可见）===
    const bubbleCount = 7;
    final riseH = math.max(60.0, groundY - topInset - 30);
    for (var i = 0; i < bubbleCount; i++) {
      final phase = (t + i * 0.15 + 0.05) % 1.0;
      final fade = _sin2(math.pi * phase);
      if (fade <= 0.01) continue;
      final rise = _easeOut(_clamp01(phase * 1.2));
      final baseX = (i + 0.5) * w / bubbleCount + _noise(i * 41 + 5) * 42;
      // 横向轻飘：sin(2π·t) 整数圈，回绕处无突变
      final px = baseX + math.sin(t * math.pi * 2 + i * 2) * 12;
      final py = groundY - rise * riseH;
      final breathe = 1 + math.sin(t * math.pi * 2 + i) * 0.05;
      final r =
          (2.5 + (_noise(i * 17 + 2) * 0.5 + 0.5) * 4.0) * breathe; // 2.5~6.5
      // 外圈柔光 + 半透球体 + 左上高光
      canvas.drawCircle(
        Offset(px, py),
        r * 1.6,
        _withAlpha(bubbleGlowPaint, fade),
      );
      canvas.drawCircle(Offset(px, py), r, _withAlpha(bubblePaint, fade));
      canvas.drawCircle(
        Offset(px - r * 0.32, py - r * 0.32),
        r * 0.3,
        _withAlpha(highlightPaint, fade),
      );
    }
  }

  /// 画一条水平滚动的正弦海浪带（填充至屏幕底）。
  ///
  /// [baseY] 波浪中线，[amp] 振幅，[wavelength] 波长，[cyclesPerPeriod] 单动画
  /// 周期内滚动的完整波长数（整数→t 回绕时波形严格相同，无缝）。
  void _drawWaveBand(
    Canvas canvas,
    double w,
    double h,
    double baseY,
    double amp,
    double wavelength,
    int cyclesPerPeriod,
    double t,
    Paint paint,
  ) {
    final scroll = t * wavelength * cyclesPerPeriod; // 整数波长滚动
    final k = 2 * math.pi / wavelength;
    const step = 14.0;
    final path = Path()..moveTo(0, h);
    var x = 0.0;
    while (x < w) {
      path.lineTo(x, baseY + amp * math.sin(k * (x + scroll)));
      x += step;
    }
    // 补齐右边缘，保证填满到 w
    path.lineTo(w, baseY + amp * math.sin(k * (w + scroll)));
    path.lineTo(w, h);
    path.close();
    canvas.drawPath(path, paint);
  }

  /// sin² 包络：x=0/π 时为 0，用于让元素在相位回绕点（α≈0）不可见。
  static double _sin2(double x) {
    final s = math.sin(x);
    return s * s;
  }

  /// 确定性伪随机：LCG 长周期，分布均匀（同 GreenGrowthPainter）。
  static double _noise(int seed) {
    return ((seed * 9301 + 49297) % 233280) / 233280.0 * 2 - 1;
  }

  static double _clamp01(double v) => v < 0 ? 0 : (v > 1 ? 1 : v);
  static double _easeOut(double t) => 1 - (1 - t) * (1 - t);

  static Paint _withAlpha(Paint src, double fade) {
    return Paint()
      ..style = src.style
      ..strokeCap = src.strokeCap
      ..strokeWidth = src.strokeWidth
      ..color = src.color.withValues(alpha: src.color.a * fade);
  }

  @override
  bool shouldRepaint(covariant OceanPainter old) =>
      animation != old.animation ||
      isDark != old.isDark ||
      palette != old.palette ||
      topInset != old.topInset ||
      bottomInset != old.bottomInset;
}

/// 「落日余晖」主题背景动画：夕阳光晕呼吸 + 横向云丝飘移 + 光尘余烬缓缓上浮 +
/// 飞鸟剪影掠过（暖调黄昏风格）。
///
/// 单 [Animation] 驱动。**循环无缝设计**：光晕呼吸取 `sin(2π·t)` 整数圈、位置固定，
/// t 回绕（1→0）时严格相同；云丝/余烬相位系数取整数（与全局周期同频），透明度用
/// `sin²(π·phase)` 包络（两端为 0），水平/垂直回绕点 α≈0 不可见；横向浮动/闪烁
/// 取 `2π` 整数倍，回绕处无突变。仅画前景，背景透明（由 Scaffold 纯色兜底）。
/// 纯 [Path] 绘制（无 saveLayer/clipPath），元素稀疏，保证 60fps。
class SunsetPainter extends CustomPainter {
  SunsetPainter({
    required this.animation,
    required this.isDark,
    required this.palette,
    this.topInset = 0,
    this.bottomInset = 0,
  }) : super(repaint: animation);

  final Animation<double> animation;
  final bool isDark;
  final JellyPalette palette;

  /// 顶部留白：光尘上浮终点距屏幕顶的高度（避开 pinned AppBar 遮挡）。
  final double topInset;

  /// 底部留白：夕阳光晕/云丝基准线距屏幕底的高度（避开浮动导航栏等遮挡）。
  final double bottomInset;

  @override
  void paint(Canvas canvas, Size size) {
    final t = animation.value;
    final w = size.width;
    final h = size.height;
    if (w <= 0 || h <= 0) return;

    final groundY = h - bottomInset; // 地平线基准

    // 取色（随当前调色板；暗色提亮、降饱和）
    final sunCoreC = palette.warning.withValues(alpha: isDark ? 0.55 : 0.5);
    final sunGlowC = (isDark ? palette.warning : palette.primary).withValues(
      alpha: isDark ? 0.28 : 0.24,
    );
    final sunHazeC = (isDark ? palette.primaryLight : palette.accent)
        .withValues(alpha: isDark ? 0.16 : 0.14);
    final wispC = palette.accent.withValues(alpha: isDark ? 0.4 : 0.36);
    final wispC2 = (isDark ? palette.primaryLight : palette.primary).withValues(
      alpha: isDark ? 0.3 : 0.26,
    );
    final emberC = palette.warning.withValues(alpha: isDark ? 0.7 : 0.62);
    final emberGlowC = palette.warning.withValues(alpha: isDark ? 0.22 : 0.18);
    final birdC = (isDark ? palette.textPrimaryDark : palette.textPrimaryLight)
        .withValues(alpha: isDark ? 0.5 : 0.42);

    final sunCorePaint = Paint()
      ..style = PaintingStyle.fill
      ..color = sunCoreC;
    final sunGlowPaint = Paint()
      ..style = PaintingStyle.fill
      ..color = sunGlowC;
    final sunHazePaint = Paint()
      ..style = PaintingStyle.fill
      ..color = sunHazeC;
    final wispPaint = Paint()
      ..style = PaintingStyle.fill
      ..color = wispC;
    final wispPaint2 = Paint()
      ..style = PaintingStyle.fill
      ..color = wispC2;
    final emberPaint = Paint()
      ..style = PaintingStyle.fill
      ..color = emberC;
    final emberGlowPaint = Paint()
      ..style = PaintingStyle.fill
      ..color = emberGlowC;
    final birdPaint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round
      ..strokeWidth = 1.8
      ..color = birdC;

    // === 夕阳光晕（低位居中，缓慢呼吸）===
    // breathe 取 sin(2π·t) 整数圈，t 回绕处无突变；位置固定，无缝。
    final cx = w / 2;
    final cy = groundY - 18; // 贴近地平线云层上方
    final breathe = 1 + math.sin(t * math.pi * 2) * 0.08;
    final baseR = math.min(w, h) * 0.12; // 自适应尺寸
    // 由外到内三层柔光 + 核心
    canvas.drawCircle(Offset(cx, cy), baseR * 2.4 * breathe, sunHazePaint);
    canvas.drawCircle(Offset(cx, cy), baseR * 1.5 * breathe, sunGlowPaint);
    canvas.drawCircle(Offset(cx, cy), baseR * 0.8 * breathe, sunCorePaint);

    // === 横向云丝飘移（地平线附近，sin² 包络，水平回绕不可见）===
    const wispCount = 5;
    final span = w + 120; // 横向行程（略大于屏宽，两端在屏外）
    for (var i = 0; i < wispCount; i++) {
      final phase = (t + i * 0.2) % 1.0;
      final fade = _sin2(math.pi * phase);
      if (fade <= 0.01) continue;
      final px = -60 + phase * span; // 从屏外左飘到屏外右
      final py = groundY + 2 + (i - wispCount / 2) * 9 + _noise(i * 53 + 7) * 6;
      final wid = 70.0 + (_noise(i * 89 + 3) * 0.5 + 0.5) * 60; // 70~130
      // 轻微上下浮动：sin(2π·t) 整数圈
      final bob = math.sin(t * math.pi * 2 + i * 1.4) * 3;
      _drawWisp(
        canvas,
        px,
        py + bob,
        wid,
        i % 2 == 0 ? wispPaint : wispPaint2,
        fade,
      );
    }

    // === 光尘余烬缓缓上浮（sin² 包络，垂直回绕不可见）===
    const emberCount = 9;
    final riseH = math.max(80.0, groundY - topInset - 40);
    for (var i = 0; i < emberCount; i++) {
      final phase = (t + i * 0.11 + 0.03) % 1.0;
      final fade = _sin2(math.pi * phase);
      if (fade <= 0.01) continue;
      final rise = _easeOut(_clamp01(phase * 1.2));
      final baseX = (i + 0.5) * w / emberCount + _noise(i * 41 + 5) * 36;
      // 横向轻飘 + 闪烁：均取 2π 整数倍/相位基，回绕处连续
      final px = baseX + math.sin(t * math.pi * 2 + i * 2) * 14;
      final py = groundY - rise * riseH;
      final twinkle = 0.5 + 0.5 * math.sin(phase * math.pi * 2 + i);
      final r = 1.4 + (_noise(i * 17 + 2) * 0.5 + 0.5) * 1.6; // 1.4~3.0
      // 外圈柔光 + 核心光点
      canvas.drawCircle(
        Offset(px, py),
        r * 2.6,
        _withAlpha(emberGlowPaint, fade * twinkle),
      );
      canvas.drawCircle(
        Offset(px, py),
        r,
        _withAlpha(emberPaint, fade * twinkle),
      );
    }

    // === 飞鸟剪影斜向飞出（sin² 包络，轨迹起止两端 α≈0 不可见）===
    // 起点散布于屏幕中下方，奇偶交替向左/右斜上方飞出，途经整个画面而非仅顶部。
    const birdCount = 3;
    final flyDist = math.max(w, h) * 0.95; // 飞出屏外的行程
    for (var i = 0; i < birdCount; i++) {
      final phase = (t + i * 0.33 + 0.1) % 1.0;
      final fade = _sin2(math.pi * phase);
      if (fade <= 0.01) continue;
      // 起点：横向铺开 + 纵向偏低（离地 45~100），错峰分散
      final startX = w * (0.2 + i * 0.25 + _noise(i * 73 + 11) * 0.1);
      final startY = groundY - (45 + (_noise(i * 137 + 5) * 0.5 + 0.5) * 55);
      // 方向：奇偶交替向左/右斜上飞；仰角 40°~65° 各异
      final dir = (i % 2 == 0) ? 1.0 : -1.0;
      final angle =
          (40 + (_noise(i * 53 + 7) * 0.5 + 0.5) * 25) * math.pi / 180;
      final dx = dir * math.cos(angle) * flyDist;
      final dy = -math.sin(angle) * flyDist; // 向上
      final px = startX + phase * dx;
      final py = startY + phase * dy;
      // 扇翅：sin(6π·t) = 3 整圈/周期，t 回绕处连续
      final flap = math.sin(t * math.pi * 6 + i * 2);
      canvas.save();
      canvas.translate(px, py);
      canvas.rotate(dir * 0.22); // 顺飞行方向轻微倾斜
      _drawBird(canvas, 0, 0, 9, flap, _withAlpha(birdPaint, fade));
      canvas.restore();
    }

    // === 顶部飞鸟水平掠过（sin² 包络，水平回绕不可见）===
    const topBirdCount = 2;
    final topSpan = w + 120;
    for (var i = 0; i < topBirdCount; i++) {
      final phase = (t + i * 0.5 + 0.3) % 1.0;
      final fade = _sin2(math.pi * phase);
      if (fade <= 0.01) continue;
      final px = -60 + phase * topSpan; // 从屏外左飞到屏外右
      final py = topInset + 40 + i * 26 + _noise(i * 191 + 4) * 16;
      // 扇翅：sin(6π·t) = 3 整圈/周期，t 回绕处连续
      final flap = math.sin(t * math.pi * 6 + i * 2 + 1);
      _drawBird(canvas, px, py, 9, flap, _withAlpha(birdPaint, fade));
    }
  }

  /// 画一道柔和条带状云丝（三段重叠椭圆，中间厚两端薄）。
  void _drawWisp(
    Canvas canvas,
    double cx,
    double cy,
    double wid,
    Paint paint,
    double fade,
  ) {
    canvas.drawOval(
      Rect.fromCenter(center: Offset(cx, cy), width: wid, height: 8),
      _withAlpha(paint, fade * 0.5),
    );
    canvas.drawOval(
      Rect.fromCenter(center: Offset(cx, cy), width: wid * 0.65, height: 6),
      _withAlpha(paint, fade * 0.8),
    );
    canvas.drawOval(
      Rect.fromCenter(center: Offset(cx, cy), width: wid * 0.35, height: 4),
      _withAlpha(paint, fade),
    );
  }

  /// 画一只飞鸟剪影（双弧 ~ 形，翅膀随 [flap] 上下摆动）。
  void _drawBird(
    Canvas canvas,
    double cx,
    double cy,
    double s,
    double flap,
    Paint paint,
  ) {
    final wing = 0.35 + flap * 0.25; // 翅膀上扬/下垂幅度
    final path = Path()
      ..moveTo(cx - s, cy + s * wing)
      ..quadraticBezierTo(cx - s * 0.5, cy - s * 0.3, cx, cy)
      ..quadraticBezierTo(cx + s * 0.5, cy - s * 0.3, cx + s, cy + s * wing);
    canvas.drawPath(path, paint);
  }

  /// sin² 包络：x=0/π 时为 0，用于让元素在相位回绕点（α≈0）不可见。
  static double _sin2(double x) {
    final s = math.sin(x);
    return s * s;
  }

  /// 确定性伪随机：LCG 长周期，分布均匀（同 GreenGrowthPainter）。
  static double _noise(int seed) {
    return ((seed * 9301 + 49297) % 233280) / 233280.0 * 2 - 1;
  }

  static double _clamp01(double v) => v < 0 ? 0 : (v > 1 ? 1 : v);
  static double _easeOut(double t) => 1 - (1 - t) * (1 - t);

  static Paint _withAlpha(Paint src, double fade) {
    return Paint()
      ..style = src.style
      ..strokeCap = src.strokeCap
      ..strokeWidth = src.strokeWidth
      ..color = src.color.withValues(alpha: src.color.a * fade);
  }

  @override
  bool shouldRepaint(covariant SunsetPainter old) =>
      animation != old.animation ||
      isDark != old.isDark ||
      palette != old.palette ||
      topInset != old.topInset ||
      bottomInset != old.bottomInset;
}

/// 「蓝色天空」主题背景动画：飘动云朵 + 阳光光斑闪烁 + 飞鸟剪影掠过 +
/// 底部草甸（起伏绿丘 + 草丛野花 + 蝴蝶低飞）（晴朗白日天空风格）。
///
/// 单 [Animation] 驱动。**循环无缝设计**：云朵/飞鸟/野花相位系数取整数（与全局
/// 周期同频），透明度用 `sin²(π·phase)` 包络（两端为 0），回绕点 α≈0 不可见；
/// 光斑闪烁、云朵浮动、飞鸟扇翅均取 `2π` 整数倍（飞鸟取 6π = 3 整圈）；丘陵静态，
/// 蝴蝶走 Lissajous(2π:4π) 8 字轨迹 + 扑翼 sin(32π·t)（均整数圈），全程连续、
/// t 回绕（1→0）时无突变。仅画前景，背景透明（由 Scaffold 纯色兜底）。纯 [Path]
/// 绘制（无 saveLayer/clipPath），元素稀疏，保证 60fps。
class SkyPainter extends CustomPainter {
  SkyPainter({
    required this.animation,
    required this.isDark,
    required this.palette,
    this.topInset = 0,
    this.bottomInset = 0,
  }) : super(repaint: animation);

  final Animation<double> animation;
  final bool isDark;
  final JellyPalette palette;

  /// 顶部留白：云朵/飞鸟生成区距屏幕顶的高度（避开 pinned AppBar 遮挡）。
  final double topInset;

  /// 底部留白：光斑分布下限距屏幕底的高度（避开浮动导航栏等遮挡）。
  final double bottomInset;

  @override
  void paint(Canvas canvas, Size size) {
    final t = animation.value;
    final w = size.width;
    final h = size.height;
    if (w <= 0 || h <= 0) return;

    final groundY = h - bottomInset; // 光斑分布下限

    // 取色（随当前调色板；暗色提亮、降饱和）
    final cloudC = Colors.white.withValues(alpha: isDark ? 0.5 : 0.6);
    final cloudShadeC = palette.primaryLight.withValues(
      alpha: isDark ? 0.3 : 0.26,
    );
    final sparkleC = palette.accent.withValues(alpha: isDark ? 0.75 : 0.7);
    final sparkleGlowC = palette.accent.withValues(alpha: isDark ? 0.22 : 0.18);
    final birdC = (isDark ? palette.textPrimaryDark : palette.primaryDark)
        .withValues(alpha: isDark ? 0.5 : 0.42);
    // 底部草甸取色
    final farHillC = (isDark ? palette.primaryLight : palette.primary)
        .withValues(alpha: isDark ? 0.35 : 0.3);
    final nearHillC = palette.success.withValues(alpha: isDark ? 0.5 : 0.45);
    final flowerC = palette.accent.withValues(alpha: isDark ? 0.85 : 0.8);
    final flowerC2 = Colors.white.withValues(alpha: isDark ? 0.75 : 0.7);
    final flowerCoreC = palette.warning.withValues(alpha: isDark ? 0.9 : 0.85);
    final bfWingC = palette.accent.withValues(alpha: isDark ? 0.82 : 0.78);
    final bfWing2C = palette.primaryLight.withValues(
      alpha: isDark ? 0.7 : 0.65,
    );
    final bfBodyC = (isDark ? palette.textPrimaryDark : palette.primaryDark)
        .withValues(alpha: isDark ? 0.6 : 0.55);

    final cloudPaint = Paint()
      ..style = PaintingStyle.fill
      ..color = cloudC;
    final cloudShadePaint = Paint()
      ..style = PaintingStyle.fill
      ..color = cloudShadeC;
    final sparklePaint = Paint()
      ..style = PaintingStyle.fill
      ..color = sparkleC;
    final sparkleGlowPaint = Paint()
      ..style = PaintingStyle.fill
      ..color = sparkleGlowC;
    final birdPaint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round
      ..strokeWidth = 1.8
      ..color = birdC;
    final farHillPaint = Paint()
      ..style = PaintingStyle.fill
      ..color = farHillC;
    final nearHillPaint = Paint()
      ..style = PaintingStyle.fill
      ..color = nearHillC;
    final flowerPaint = Paint()
      ..style = PaintingStyle.fill
      ..color = flowerC;
    final flower2Paint = Paint()
      ..style = PaintingStyle.fill
      ..color = flowerC2;
    final flowerCorePaint = Paint()
      ..style = PaintingStyle.fill
      ..color = flowerCoreC;
    final bfWingPaint = Paint()
      ..style = PaintingStyle.fill
      ..color = bfWingC;
    final bfWing2Paint = Paint()
      ..style = PaintingStyle.fill
      ..color = bfWing2C;
    final bfBodyPaint = Paint()
      ..style = PaintingStyle.fill
      ..color = bfBodyC;

    // === 飘动云朵（上部，sin² 包络，水平回绕不可见）===
    const cloudCount = 4;
    final span = w + 160; // 横向行程（两端在屏外）
    for (var i = 0; i < cloudCount; i++) {
      final phase = (t + i * 0.25) % 1.0;
      final fade = _sin2(math.pi * phase);
      if (fade <= 0.01) continue;
      final px = -80 + phase * span; // 从屏外左飘到屏外右
      final baseY = topInset + 30 + (i % 3) * 36 + _noise(i * 73 + 11) * 18;
      final bob = math.sin(t * math.pi * 2 + i * 1.7) * 3; // 整数圈浮动
      final scale = 0.85 + (_noise(i * 137 + 5) * 0.5 + 0.5) * 0.5; // 0.85~1.35
      _drawCloud(
        canvas,
        px,
        baseY + bob,
        26 * scale,
        cloudPaint,
        cloudShadePaint,
        fade,
      );
    }

    // === 阳光光斑闪烁（全屏稀疏，原地闪烁 + 微浮）===
    // twinkle 取 sin(2π·t) 整数圈，t 回绕处连续无突变（无需 fade 包络）。
    final sparkleCount = math.max(14, (w * h / 22000).floor());
    for (var i = 0; i < sparkleCount; i++) {
      final tw = 0.5 + 0.5 * math.sin(t * math.pi * 2 + i * 1.3);
      if (tw <= 0.08) continue;
      final x = (_noise(i * 73 + 11) * 0.5 + 0.5) * w;
      final y =
          topInset + (_noise(i * 137 + 5) * 0.5 + 0.5) * (groundY - topInset);
      final bob = math.sin(t * math.pi * 2 + i) * 4; // 整数圈微浮
      final r = 0.9 + (_noise(i * 211) * 0.5 + 0.5) * 1.2; // 0.9~2.1
      canvas.drawCircle(
        Offset(x, y + bob),
        r * 2.4,
        _withAlpha(sparkleGlowPaint, tw),
      );
      canvas.drawCircle(Offset(x, y + bob), r, _withAlpha(sparklePaint, tw));
    }

    // === 飞鸟剪影掠过（sin² 包络，水平回绕不可见）===
    const birdCount = 3;
    final birdSpan = w + 120;
    for (var i = 0; i < birdCount; i++) {
      final phase = (t + i * 0.33 + 0.15) % 1.0;
      final fade = _sin2(math.pi * phase);
      if (fade <= 0.01) continue;
      final px = -60 + phase * birdSpan; // 从屏外左飞到屏外右
      final py = topInset + 44 + i * 46 + _noise(i * 89 + 7) * 26;
      // 扇翅：sin(6π·t) = 3 整圈/周期，t 回绕处连续
      final flap = math.sin(t * math.pi * 6 + i * 2);
      _drawBird(canvas, px, py, 10, flap, _withAlpha(birdPaint, fade));
    }

    // === 底部草甸：远景蓝丘 + 近景绿丘（静态地平线）===
    final farBaseY = groundY - 26;
    const farAmp = 14.0;
    final farWL = math.max(160.0, w * 0.55);
    _drawHill(canvas, w, h, farBaseY, farAmp, farWL, farHillPaint);
    final nearBaseY = groundY - 6;
    const nearAmp = 22.0;
    final nearWL = math.max(240.0, w * 0.85);
    final kNear = 2 * math.pi / nearWL;
    _drawHill(canvas, w, h, nearBaseY, nearAmp, nearWL, nearHillPaint);

    // === 草丛野花（贴在近丘表面，sin² 绽放/凋谢）===
    const flowerCount = 8;
    for (var i = 0; i < flowerCount; i++) {
      final phase = (t + i * 0.12 + 0.05) % 1.0;
      final fade = _sin2(math.pi * phase);
      if (fade <= 0.01) continue;
      final bloom = _easeOut(_clamp01(phase * 2.2));
      final fx = (i + 0.5) * w / flowerCount + _noise(i * 41 + 3) * 16;
      final fy = nearBaseY + nearAmp * math.sin(kNear * fx) - 5; // 贴地面
      final r = 3.2 * bloom;
      final wp = i % 2 == 0 ? flowerPaint : flower2Paint;
      // 4 瓣小花：十字双椭圆 + 花心
      canvas.drawOval(
        Rect.fromCenter(
          center: Offset(fx, fy),
          width: r * 1.9,
          height: r * 0.95,
        ),
        _withAlpha(wp, fade),
      );
      canvas.drawOval(
        Rect.fromCenter(
          center: Offset(fx, fy),
          width: r * 0.95,
          height: r * 1.9,
        ),
        _withAlpha(wp, fade),
      );
      canvas.drawCircle(
        Offset(fx, fy),
        r * 0.45,
        _withAlpha(flowerCorePaint, fade),
      );
    }

    // === 蝴蝶低空扑翼（Lissajous 8 字轨迹 + ~1Hz 扑翼，整数圈全程无缝、持续可见）===
    const butterflyCount = 3;
    for (var i = 0; i < butterflyCount; i++) {
      final cx = (i + 0.5) * w / butterflyCount + _noise(i * 73 + 11) * 28;
      final cy = groundY - 72 + _noise(i * 137 + 5) * 22;
      // 8 字轨迹：sin(2π·t) × sin(4π·t)，整数圈→t 回绕连续
      final px = cx + math.sin(t * math.pi * 2 + i * 1.3) * 26;
      final py = cy + math.sin(t * math.pi * 4 + i * 0.7) * 15;
      // 扑翼：sin(32π·t) ≈ 1Hz，16 整圈→回绕连续
      final open = 0.5 + 0.5 * math.sin(t * math.pi * 32 + i * 2);
      _drawButterfly(
        canvas,
        px,
        py,
        7,
        open,
        i % 2 == 0 ? bfWingPaint : bfWing2Paint,
        bfBodyPaint,
        1.0,
      );
    }
  }

  /// 画一朵蓬松云：底部蓝阴影 + 上部白色重叠圆。
  void _drawCloud(
    Canvas canvas,
    double cx,
    double cy,
    double r,
    Paint paint,
    Paint shadePaint,
    double fade,
  ) {
    // 底部阴影（蓝色底）
    canvas.drawCircle(
      Offset(cx - r * 0.8, cy + r * 0.25),
      r * 0.72,
      _withAlpha(shadePaint, fade),
    );
    canvas.drawCircle(
      Offset(cx + r * 0.9, cy + r * 0.3),
      r * 0.66,
      _withAlpha(shadePaint, fade),
    );
    // 主体（白色重叠圆）
    canvas.drawCircle(
      Offset(cx - r * 0.9, cy),
      r * 0.8,
      _withAlpha(paint, fade),
    );
    canvas.drawCircle(Offset(cx, cy - r * 0.3), r, _withAlpha(paint, fade));
    canvas.drawCircle(Offset(cx + r, cy), r * 0.85, _withAlpha(paint, fade));
    canvas.drawCircle(
      Offset(cx + r * 0.1, cy + r * 0.15),
      r * 0.7,
      _withAlpha(paint, fade),
    );
  }

  /// 画一条静态正弦丘陵带（填充至屏幕底，作地平线）。
  void _drawHill(
    Canvas canvas,
    double w,
    double h,
    double baseY,
    double amp,
    double wavelength,
    Paint paint,
  ) {
    final k = 2 * math.pi / wavelength;
    const step = 16.0;
    final path = Path()..moveTo(0, h);
    var x = 0.0;
    while (x < w) {
      path.lineTo(x, baseY + amp * math.sin(k * x));
      x += step;
    }
    path.lineTo(w, baseY + amp * math.sin(k * w));
    path.lineTo(w, h);
    path.close();
    canvas.drawPath(path, paint);
  }

  /// 画一只蝴蝶：左右翼随 [open]（0~1）开合扑动 + 细长身体。
  void _drawButterfly(
    Canvas canvas,
    double cx,
    double cy,
    double s,
    double open,
    Paint wingPaint,
    Paint bodyPaint,
    double fade,
  ) {
    final ww = s * (0.55 + 0.55 * open); // 翼宽随开合
    final wh = s * 1.15; // 翼高
    canvas.save();
    canvas.translate(cx, cy);
    canvas.drawOval(
      Rect.fromCenter(
        center: Offset(-ww * 0.5, -s * 0.1),
        width: ww,
        height: wh,
      ),
      _withAlpha(wingPaint, fade),
    );
    canvas.drawOval(
      Rect.fromCenter(
        center: Offset(ww * 0.5, -s * 0.1),
        width: ww,
        height: wh,
      ),
      _withAlpha(wingPaint, fade),
    );
    canvas.drawOval(
      Rect.fromCenter(center: Offset.zero, width: s * 0.2, height: s * 0.95),
      _withAlpha(bodyPaint, fade),
    );
    canvas.restore();
  }

  static double _clamp01(double v) => v < 0 ? 0 : (v > 1 ? 1 : v);
  static double _easeOut(double t) => 1 - (1 - t) * (1 - t);

  /// 画一只飞鸟剪影（双弧 ~ 形，翅膀随 [flap] 上下摆动）。
  void _drawBird(
    Canvas canvas,
    double cx,
    double cy,
    double s,
    double flap,
    Paint paint,
  ) {
    final wing = 0.35 + flap * 0.25; // 翅膀上扬/下垂幅度
    final path = Path()
      ..moveTo(cx - s, cy + s * wing)
      ..quadraticBezierTo(cx - s * 0.5, cy - s * 0.3, cx, cy)
      ..quadraticBezierTo(cx + s * 0.5, cy - s * 0.3, cx + s, cy + s * wing);
    canvas.drawPath(path, paint);
  }

  /// sin² 包络：x=0/π 时为 0，用于让元素在相位回绕点（α≈0）不可见。
  static double _sin2(double x) {
    final s = math.sin(x);
    return s * s;
  }

  /// 确定性伪随机：LCG 长周期，分布均匀（同 GreenGrowthPainter）。
  static double _noise(int seed) {
    return ((seed * 9301 + 49297) % 233280) / 233280.0 * 2 - 1;
  }

  static Paint _withAlpha(Paint src, double fade) {
    return Paint()
      ..style = src.style
      ..strokeCap = src.strokeCap
      ..strokeWidth = src.strokeWidth
      ..color = src.color.withValues(alpha: src.color.a * fade);
  }

  @override
  bool shouldRepaint(covariant SkyPainter old) =>
      animation != old.animation ||
      isDark != old.isDark ||
      palette != old.palette ||
      topInset != old.topInset ||
      bottomInset != old.bottomInset;
}

/// 按主题预设 id 取背景动画 painter。
///
/// 内置 6 套预设各有专属动画：green = 植物生长；jelly = 梦幻星夜；pink = 樱花飘落；
/// ocean = 海浪气泡；sunset = 落日余晖；sky = 蓝天白云；
/// 自定义/未知主题返回 null（降级为纯色背景）。新增主题动画只需在此注册 + 新建 painter。
CustomPainter? backgroundPainterFor(
  String presetId,
  Animation<double> animation,
  bool isDark,
  JellyPalette palette, {
  double topInset = 0,
  double bottomInset = 0,
  int cycle = 0,
}) {
  switch (presetId) {
    case 'green':
      return GreenGrowthPainter(
        animation: animation,
        isDark: isDark,
        palette: palette,
        topInset: topInset,
        bottomInset: bottomInset,
      );
    case 'jelly':
      return JellyStarryNightPainter(
        animation: animation,
        isDark: isDark,
        palette: palette,
        topInset: topInset,
        bottomInset: bottomInset,
        cycle: cycle,
      );
    case 'pink':
      return SakuraPainter(
        animation: animation,
        isDark: isDark,
        palette: palette,
        topInset: topInset,
        bottomInset: bottomInset,
      );
    case 'ocean':
      return OceanPainter(
        animation: animation,
        isDark: isDark,
        palette: palette,
        topInset: topInset,
        bottomInset: bottomInset,
      );
    case 'sunset':
      return SunsetPainter(
        animation: animation,
        isDark: isDark,
        palette: palette,
        topInset: topInset,
        bottomInset: bottomInset,
      );
    case 'sky':
      return SkyPainter(
        animation: animation,
        isDark: isDark,
        palette: palette,
        topInset: topInset,
        bottomInset: bottomInset,
      );
    default:
      return null;
  }
}
