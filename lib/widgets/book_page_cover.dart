import 'package:flutter/material.dart';

/// 覆盖翻页：新页从边缘滑入，覆盖在当前页之上（当前页静止）。
///
/// 下一页：[nextPage] 从右侧滑入；上一页：[prevPage] 从左侧滑入。无卷曲变形，
/// 直接平移真实 widget，动画期间不栅格化、不丢失选字语义层（动画结束即恢复）。
///
/// 交互同 [BookPageCurl]：点左 1/3 上一页、右 1/3 下一页、中间显隐控件栏；
/// 左右拖动翻页；长按(>350ms)或拖动(>18px)放行给下层 SelectableText，仅短按
/// 单击才翻页。
class BookPageCover extends StatefulWidget {
  final Widget page; // 当前页（静止，底层）
  final Widget? nextPage; // 下一页（从右滑入覆盖）
  final Widget? prevPage; // 上一页（从左滑入覆盖）
  final Color backgroundColor; // 滑入页底色：不透明，覆盖当前页文字避免重叠
  final bool canNext;
  final bool canPrev;
  final VoidCallback onTurnNext;
  final VoidCallback onTurnPrev;
  final VoidCallback onTapCenter;

  const BookPageCover({
    super.key,
    required this.page,
    required this.backgroundColor,
    this.nextPage,
    this.prevPage,
    this.canNext = true,
    this.canPrev = true,
    required this.onTurnNext,
    required this.onTurnPrev,
    required this.onTapCenter,
  });

  @override
  State<BookPageCover> createState() => _BookPageCoverState();
}

class _BookPageCoverState extends State<BookPageCover>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl;
  late final Animation<double> _anim;
  bool _animating = false;
  int _direction = 0; // 1=下一页(从右滑入), -1=上一页(从左滑入)

  Offset? _downPos;
  DateTime? _downTime;
  double _dragDx = 0;
  double _width = 0;

  static const _shadowWidth = 24.0;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 320),
    );
    _anim = CurvedAnimation(parent: _ctrl, curve: Curves.easeOutCubic);
    _ctrl.addListener(() {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  void _turn(int dir) {
    if (_animating) return;
    if (dir == 1 && !widget.canNext) return;
    if (dir == -1 && !widget.canPrev) return;
    setState(() {
      _direction = dir;
      _animating = true;
    });
    _ctrl.forward(from: 0).then((_) {
      if (!mounted) return;
      final d = _direction;
      setState(() {
        _animating = false;
        _direction = 0;
      });
      if (d == 1) {
        widget.onTurnNext();
      } else if (d == -1) {
        widget.onTurnPrev();
      }
    });
  }

  void _onPointerDown(PointerDownEvent e) {
    _downPos = e.position;
    _downTime = DateTime.now();
  }

  void _onPointerUp(PointerUpEvent e) {
    if (_animating) return; // 翻页中忽略
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
      if (widget.canPrev) _turn(-1);
    } else if (dx > w * 2 / 3) {
      if (widget.canNext) _turn(1);
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
    if (_animating) return; // 翻页中忽略
    final dx = _dragDx;
    _dragDx = 0;
    final v = d.primaryVelocity ?? 0;
    final w = _width;
    // 向左滑(dx<0 / v<0)=下一页，向右滑=上一页；位移达 18% 宽度或速度足够即触发
    final goNext = dx < -w * 0.18 || v < -350;
    final goPrev = dx > w * 0.18 || v > 350;
    if (goNext && widget.canNext) {
      _turn(1);
    } else if (goPrev && widget.canPrev) {
      _turn(-1);
    }
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
    // 静止：仅显示当前页
    if (!_animating) {
      return [Positioned.fill(child: widget.page)];
    }
    final t = _anim.value;
    final dir = _direction;
    final slide = (1 - t) * w * dir;
    final content = dir == 1 ? widget.nextPage : widget.prevPage;
    // 滑动页前沿 x（dir=1: 左沿=slide；dir=-1: 右沿=w+slide）
    final leadingEdge = dir == 1 ? slide : (w + slide);
    return [
      Positioned.fill(child: widget.page),
      if (content != null)
        Transform.translate(
          offset: Offset(slide, 0),
          child: IgnorePointer(
            child: ColoredBox(
              color: widget.backgroundColor,
              child: SizedBox(width: w, height: h, child: content),
            ),
          ),
        ),
      // 投影：落在静止页上、紧贴滑动页前沿，朝滑动页方向渐深
      Positioned(
        top: 0,
        bottom: 0,
        left: dir == 1 ? (leadingEdge - _shadowWidth) : leadingEdge,
        width: _shadowWidth,
        child: IgnorePointer(
          child: DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.centerLeft,
                end: Alignment.centerRight,
                colors: dir == 1
                    ? [Colors.transparent, Colors.black.withValues(alpha: 0.28)]
                    : [Colors.black.withValues(alpha: 0.28), Colors.transparent],
              ),
            ),
          ),
        ),
      ),
    ];
  }
}
