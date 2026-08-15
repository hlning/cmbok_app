import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';

/// 仿真翻页（圆柱卷曲 + 栅格化）。
///
/// 触发翻页时把当前页用 [RepaintBoundary.toImage] 栅格成 [ui.Image]，再按
/// 经典三段 page-curl 模型绘制：
///   未卷平面段（正面文字，静止）-> 卷曲圆柱段（文字随曲面卷曲变形）->
///   已翻平面段（翻过去的纸背，沿圆柱切线平铺）。
///
/// 文字段逐列用 `clipPath`(列四边形) + `drawImageRect`(该列图片条带->外接矩形)
/// 绘制，绕开 drawVertices/ImageShader 的纹理坑，保证文字随曲面附着。
/// 阴影/纸背用 `drawPath` 填色。
///
/// 代价：翻页动画期间翻起页为栅格化图片，丢失 [SelectableText] 语义层，
/// 无法长按选字；动画结束释放图片、恢复真实 widget，选字能力恢复。
///
/// 交互同前：点左 1/3 上一页、右 1/3 下一页、中间显隐控件栏；长按(>350ms)
/// 或拖动(>18px) 放行给下层 SelectableText，仅短按单击才翻页。
class BookPageCurl extends StatefulWidget {
  final Widget page; // 当前页
  final Widget? nextPage; // 下一页（向左翻时露出）
  final Widget? prevPage; // 上一页（向右翻时露出）
  final Widget background; // 翻页时底层背景
  final bool canNext;
  final bool canPrev;
  final VoidCallback onTurnNext;
  final VoidCallback onTurnPrev;
  final VoidCallback onTapCenter;

  const BookPageCurl({
    super.key,
    required this.page,
    required this.background,
    this.nextPage,
    this.prevPage,
    this.canNext = true,
    this.canPrev = true,
    required this.onTurnNext,
    required this.onTurnPrev,
    required this.onTapCenter,
  });

  @override
  State<BookPageCurl> createState() => _BookPageCurlState();
}

class _BookPageCurlState extends State<BookPageCurl>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl;
  late final Animation<double> _anim;
  final GlobalKey _pageKey = GlobalKey();

  _Phase _phase = _Phase.idle; // idle / rasterizing / animating
  int _direction = 0; // 1=下一页(向左翻), -1=上一页(向右翻)
  ui.Image? _pageImage; // 翻起页栅格化结果
  double _width = 0;

  Offset? _downPos;
  DateTime? _downTime;
  double _dragDx = 0; // 水平滑动累计位移，用于判定翻页方向

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 520),
    );
    _anim = CurvedAnimation(parent: _ctrl, curve: Curves.easeInOutCubic);
    _ctrl.addListener(() {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _pageImage?.dispose();
    _ctrl.dispose();
    super.dispose();
  }

  double get _progress => _anim.value;

  void _onPointerDown(PointerDownEvent e) {
    _downPos = e.position;
    _downTime = DateTime.now();
  }

  void _onPointerUp(PointerUpEvent e) {
    if (_phase != _Phase.idle) return; // 翻页中忽略
    final pos = _downPos;
    final t = _downTime;
    _downPos = null;
    _downTime = null;
    if (pos == null || t == null) return;
    final dist = (e.position - pos).distance;
    final dt = DateTime.now().difference(t).inMilliseconds;
    // 长按选字(>350ms)或拖动选区(位移大)交给下层 SelectableText，仅短按单击才翻页
    if (dist > 18 || dt > 350) return;
    final w = _width;
    if (w <= 0) return;
    final dx = e.position.dx;
    if (dx < w / 3) {
      if (widget.canPrev) _animateTurn(-1);
    } else if (dx > w * 2 / 3) {
      if (widget.canNext) _animateTurn(1);
    } else {
      widget.onTapCenter();
    }
  }

  // 左右滑动翻页（仅水平拖动；长按选字、竖向拖动仍归 SelectableText）
  void _onHorizontalDragStart(DragStartDetails _) {
    _dragDx = 0;
  }

  void _onHorizontalDragUpdate(DragUpdateDetails d) {
    _dragDx += d.delta.dx;
  }

  void _onHorizontalDragEnd(DragEndDetails d) {
    if (_phase != _Phase.idle) return; // 翻页中忽略
    final dx = _dragDx;
    _dragDx = 0;
    final v = d.primaryVelocity ?? 0;
    final w = _width;
    // 向左滑(dx<0 / v<0)=下一页，向右滑=上一页；位移达 18% 宽度或速度足够即触发
    final goNext = dx < -w * 0.18 || v < -350;
    final goPrev = dx > w * 0.18 || v > 350;
    if (goNext && widget.canNext) {
      _animateTurn(1);
    } else if (goPrev && widget.canPrev) {
      _animateTurn(-1);
    }
  }

  Future<void> _animateTurn(int dir) async {
    if (_phase != _Phase.idle) return;
    setState(() {
      _direction = dir;
      _phase = _Phase.rasterizing;
    });
    final image = await _rasterizePage();
    if (!mounted || _phase != _Phase.rasterizing || _direction != dir) {
      image?.dispose();
      return;
    }
    _pageImage = image;
    setState(() => _phase = _Phase.animating);
    _ctrl.value = 0;
    await _ctrl.forward();
    if (!mounted) return;
    _finishTurn();
  }

  Future<ui.Image?> _rasterizePage() async {
    final ctx = _pageKey.currentContext;
    if (ctx == null) return null;
    final ro = ctx.findRenderObject();
    if (ro is! RenderRepaintBoundary || !ro.hasSize) return null;
    final ratio = (MediaQuery.maybeDevicePixelRatioOf(context) ?? 2.0).clamp(
      1.0,
      2.5,
    );
    try {
      return await ro.toImage(pixelRatio: ratio);
    } catch (_) {
      return null;
    }
  }

  void _finishTurn() {
    if (_direction == 1) {
      widget.onTurnNext();
    } else if (_direction == -1) {
      widget.onTurnPrev();
    }
    _reset();
  }

  void _reset() {
    if (!mounted) return;
    _pageImage?.dispose();
    _pageImage = null;
    setState(() {
      _direction = 0;
      _phase = _Phase.idle;
      _ctrl.value = 0;
    });
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, c) {
        _width = c.maxWidth;
        final w = c.maxWidth;
        final h = c.maxHeight;
        return Listener(
          behavior: HitTestBehavior.translucent,
          onPointerDown: _onPointerDown,
          onPointerUp: _onPointerUp,
          child: GestureDetector(
            behavior: HitTestBehavior.translucent,
            onHorizontalDragStart: _onHorizontalDragStart,
            onHorizontalDragUpdate: _onHorizontalDragUpdate,
            onHorizontalDragEnd: _onHorizontalDragEnd,
            child: Stack(fit: StackFit.expand, children: _buildChildren(w, h)),
          ),
        );
      },
    );
  }

  List<Widget> _buildChildren(double w, double h) {
    // 静止 / 栅格化中：显示真实当前页（RepaintBoundary 供 toImage 取图）
    if (_phase != _Phase.animating || _pageImage == null) {
      return [
        Positioned.fill(child: widget.background),
        Positioned.fill(
          child: RepaintBoundary(key: _pageKey, child: widget.page),
        ),
      ];
    }
    // 动画中：下方露出目标页，上层 CustomPaint 画卷曲的翻起页
    final target = _direction == 1 ? widget.nextPage : widget.prevPage;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return [
      Positioned.fill(child: widget.background),
      Positioned.fill(
        child: IgnorePointer(child: target ?? const SizedBox.shrink()),
      ),
      Positioned.fill(
        child: IgnorePointer(
          child: CustomPaint(
            painter: _CurlPainter(
              image: _pageImage!,
              direction: _direction,
              progress: _progress,
              width: w,
              height: h,
              isDark: isDark,
            ),
          ),
        ),
      ),
    ];
  }
}

enum _Phase { idle, rasterizing, animating }

enum _Seg { flat, curl }

/// 网格列：原页面 x（纹理）、3D 坐标、所属段与参数 t。
class _Col {
  final double xOrig, x3d, z;
  final _Seg seg;
  final double t; // flat: frac(0远端..1轴); curl: phi/mid(0轴..1=90°)
  _Col(this.xOrig, this.x3d, this.z, this.seg, this.t);
}

/// 逐列绘制图片文字：把 image 的竖条 [tx0,tx1]×[0,imgH] 用 drawImageRect
/// 画进屏幕四边形 (top0,bot0,top1,bot1) 的外接矩形，clipPath 塑形为四边形。
/// flat 列精确；curl 列窄列透视失真可忽略（仿射 b=d=0，外接矩形+clip 等价）。
/// 用 drawImageRect 而非 drawImage+transform，避免整图变换+裁剪不渲染。
void _drawTextColumn(
  Canvas canvas,
  ui.Image image,
  double imgH,
  double tx0,
  double tx1,
  Offset top0,
  Offset bot0,
  Offset top1,
  Offset bot1,
) {
  if ((tx1 - tx0).abs() < 1e-3) return;
  // 把 image 的源竖条带 [tx0,tx1]×[0,imgH] 用 drawImageRect 画进该列四边形的
  // 外接矩形，再用 clipPath 塑形为四边形。flat 列外接矩形==四边形（精确）；
  // curl 列因仿射 b=d=0 本就只有缩放、无透视剪切，外接矩形+clip 与原仿射等价。
  // 用 drawImageRect 而非 drawImage+canvas.transform，避免整图变换+裁剪不渲染；
  // 每列只画窄条带也更轻量。tx0/tx1 与 top0/top1 经 min/max 归一化，兼容
  // sign=-1（xOrig 递减）方向且不水平翻转。
  final srcLeft = math.min(tx0, tx1);
  final srcRight = math.max(tx0, tx1);
  final dst = Rect.fromLTRB(
    math.min(top0.dx, top1.dx),
    0.0,
    math.max(top0.dx, top1.dx),
    math.max(bot0.dy, bot1.dy),
  );
  canvas.save();
  canvas.clipPath(
    Path()
      ..moveTo(top0.dx, top0.dy)
      ..lineTo(top1.dx, top1.dy)
      ..lineTo(bot1.dx, bot1.dy)
      ..lineTo(bot0.dx, bot0.dy)
      ..close(),
  );
  canvas.drawImageRect(
    image,
    Rect.fromLTRB(srcLeft, 0.0, srcRight, imgH),
    dst,
    Paint(),
  );
  canvas.restore();
}

/// 三段圆柱卷曲绘制器。
///
/// 模型（sign=direction，1=向左翻下一页，-1=向右翻上一页）：
/// - 未卷平面段：轴的未卷侧，原纸张 `[flatFar, axisX]`，z=0，正面文字静止。
/// - 卷曲圆柱段：轴处半径 R 的圆柱面，弧角 θ=p·π，原纸张长 `R·θ`。φ<90°
///   正面（图片，文字随曲面变形），φ>90° 纸背（填色，无镜像文字）。
/// - 已翻平面段：圆柱末端沿切线 `(cosθ, sinθ)` 平铺的原纸张剩余部分，纸背。
/// 整体套透视相机（距离 camD）产生近大远小。
class _CurlPainter extends CustomPainter {
  final ui.Image image;
  final int direction; // 1 or -1
  final double progress;
  final double width;
  final double height;
  final bool isDark;

  _CurlPainter({
    required this.image,
    required this.direction,
    required this.progress,
    required this.width,
    required this.height,
    required this.isDark,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final w = width, h = height, p = progress;
    final sign = direction.toDouble(); // 1 or -1
    final R = w * 0.10; // 圆柱半径
    final camD = w * 3.5; // 相机距离
    final imgW = image.width.toDouble();
    final imgH = image.height.toDouble();
    final theta = p * math.pi; // 卷曲角 0..180°
    final mid = math.pi / 2;
    final axisX = sign > 0 ? w * (1 - p) : w * p; // 卷曲轴 x
    final curlLen = R * theta; // 卷曲段原长
    final flatLen = sign > 0 ? axisX : (w - axisX); // 未卷段原长
    final flipLen = (w - flatLen - curlLen).clamp(0.0, w); // 已翻段原长
    final flatFar = sign > 0 ? 0.0 : w; // 未卷段远端
    final phiFront = math.min(theta, mid);
    final hasBack = theta > mid;
    const flatCols = 6;
    const curlCols = 20;
    final frontCols = hasBack
        ? (curlCols * phiFront / theta).round().clamp(1, curlCols - 1)
        : curlCols;

    double f(double z) => camD / (camD + z);
    double px(double x3d, double z) => x3d * f(z);
    double py(double y, double z) => y * f(z);

    final backBase = isDark ? const Color(0xFF1E1E22) : const Color(0xFFFBF6EC);
    final backDark = isDark ? const Color(0xFF131316) : const Color(0xFFEFE7D6);

    Offset top(double x3d, double z) => Offset(px(x3d, z), py(0, z));
    Offset bot(double x3d, double z) => Offset(px(x3d, z), py(h, z));

    // ---- 落影：投在目标页露出侧（sign 方向，轴外侧）----
    if (p > 0) {
      final castA = 0.26 * math.sin(p * math.pi);
      if (castA > 0) {
        final sw = 30 + 60 * p;
        final left = sign > 0 ? axisX : axisX - sw;
        final rect = Rect.fromLTWH(left, 0, sw, h);
        final grad = LinearGradient(
          begin: sign > 0 ? Alignment.centerLeft : Alignment.centerRight,
          end: sign > 0 ? Alignment.centerRight : Alignment.centerLeft,
          colors: [
            Colors.black.withValues(alpha: castA),
            Colors.black.withValues(alpha: 0.0),
          ],
        );
        canvas.drawRect(rect, Paint()..shader = grad.createShader(rect));
      }
    }

    // ---- 正面文字段：未卷平面 + 卷曲正面 ----
    final cols = <_Col>[];
    for (int k = 0; k <= flatCols; k++) {
      final frac = k / flatCols; // 0=远端, 1=轴
      final xOrig = flatFar + (axisX - flatFar) * frac;
      cols.add(_Col(xOrig, xOrig, 0, _Seg.flat, frac));
    }
    if (frontCols > 0 && phiFront > 0) {
      for (int k = 1; k <= frontCols; k++) {
        // k=0 与未卷末列(轴)重合，跳过
        final phi = phiFront * k / frontCols;
        cols.add(
          _Col(
            axisX + sign * R * phi,
            axisX + sign * R * math.sin(phi),
            R * (1 - math.cos(phi)),
            _Seg.curl,
            phi / mid,
          ),
        );
      }
    }
    // 逐列画图片文字
    for (int i = 0; i < cols.length - 1; i++) {
      final c0 = cols[i], c1 = cols[i + 1];
      final tx0 = c0.xOrig / w * imgW;
      final tx1 = c1.xOrig / w * imgW;
      _drawTextColumn(
        canvas,
        image,
        imgH,
        tx0,
        tx1,
        top(c0.x3d, c0.z),
        bot(c0.x3d, c0.z),
        top(c1.x3d, c1.z),
        bot(c1.x3d, c1.z),
      );
    }
    // 自阴影（叠在文字上）：平面段近轴暗、卷曲段近轴暗
    if (p > 0) {
      final flatA = 0.20 * math.sin(p * math.pi);
      for (int i = 0; i < cols.length - 1; i++) {
        final c0 = cols[i], c1 = cols[i + 1];
        final double a;
        if (c1.seg == _Seg.flat) {
          a = flatA * c1.t; // c1.t=frac，近轴(=1)最暗
        } else {
          a = 0.34 * (1 - c0.t.clamp(0.0, 1.0)); // 卷曲段 c0.t=phi/mid，近轴(=0)最暗
        }
        if (a < 0.01) continue;
        final path = Path()
          ..moveTo(px(c0.x3d, c0.z), py(0, c0.z))
          ..lineTo(px(c1.x3d, c1.z), py(0, c1.z))
          ..lineTo(px(c1.x3d, c1.z), py(h, c1.z))
          ..lineTo(px(c0.x3d, c0.z), py(h, c0.z))
          ..close();
        canvas.drawPath(
          path,
          Paint()..color = Color.fromRGBO(0, 0, 0, a.clamp(0.0, 1.0)),
        );
      }
    }

    // ---- 卷曲背面段（纸背填色，φ mid..theta）----
    if (hasBack) {
      final backC = curlCols - frontCols;
      final span = (theta - mid).clamp(1e-6, math.pi);
      Offset? pTop, pBot;
      for (int k = 0; k <= backC; k++) {
        final phi = mid + span * k / backC;
        final x3d = axisX + sign * R * math.sin(phi);
        final z = R * (1 - math.cos(phi));
        final tTop = top(x3d, z), tBot = bot(x3d, z);
        if (pTop != null && pBot != null) {
          final t = ((k - 0.5) / backC).clamp(0.0, 1.0);
          final path = Path()
            ..moveTo(pTop.dx, pTop.dy)
            ..lineTo(tTop.dx, tTop.dy)
            ..lineTo(tBot.dx, tBot.dy)
            ..lineTo(pBot.dx, pBot.dy)
            ..close();
          canvas.drawPath(
            path,
            Paint()..color = Color.lerp(backBase, backDark, t)!,
          );
        }
        pTop = tTop;
        pBot = tBot;
      }
    }

    // ---- 已翻段（纸背填色，沿圆柱切线平铺）----
    if (flipLen > 0) {
      const flipC = 10;
      final ex = axisX + sign * R * math.sin(theta); // 圆柱末端 x3d
      final ez = R * (1 - math.cos(theta)); // 末端 z
      final tx = math.cos(theta); // 切线 x 分量
      final tz = math.sin(theta); // 切线 z 分量
      Offset? pTop, pBot;
      for (int k = 0; k <= flipC; k++) {
        final s = flipLen * k / flipC;
        final x3d = ex + sign * s * tx;
        final z = ez + s * tz;
        final tTop = top(x3d, z), tBot = bot(x3d, z);
        if (pTop != null && pBot != null) {
          final t = ((k - 0.5) / flipC * 0.7).clamp(0.0, 1.0);
          final path = Path()
            ..moveTo(pTop.dx, pTop.dy)
            ..lineTo(tTop.dx, tTop.dy)
            ..lineTo(tBot.dx, tBot.dy)
            ..lineTo(pBot.dx, pBot.dy)
            ..close();
          canvas.drawPath(
            path,
            Paint()..color = Color.lerp(backBase, backDark, t)!,
          );
        }
        pTop = tTop;
        pBot = tBot;
      }
    }
  }

  @override
  bool shouldRepaint(covariant _CurlPainter old) =>
      old.progress != progress ||
      old.direction != direction ||
      old.image != image ||
      old.width != width ||
      old.height != height;
}
