import 'package:flutter/material.dart';

/// 自定义书架图标：三根高低不同的圆角竖柱（中>左>右，左右加高缩小差距），
/// 每根柱子内部底部嵌一个横向白色长方形。柱子颜色跟随 [color]（导航选中态）。
class BookshelfIcon extends StatelessWidget {
  const BookshelfIcon({super.key, required this.color, this.size = 24});

  final Color color;
  final double size;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: size,
      height: size,
      child: CustomPaint(painter: _BookshelfPainter(color)),
    );
  }
}

class _BookshelfPainter extends CustomPainter {
  _BookshelfPainter(this.color);

  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    // 逻辑画布 24×24，按实际尺寸缩放
    final s = size.width / 24;
    final barPaint = Paint()..color = color;
    // 横条用与柱子对比的颜色：柱子偏亮（如暗色选中态为白）时用深色，否则用白色
    final shelfPaint = Paint()
      ..color = color.computeLuminance() > 0.5 ? Colors.black87 : Colors.white;

    // 三根柱子：(x, 宽, 高)，底部对齐 baseY
    // 中间最高(17)、左次之(15)、右最矮(13)--左右加高、左略高于右
    const bars = [
      (1.5, 6.0, 15.0), // 左柱
      (9.0, 6.0, 17.0), // 中柱
      (16.5, 6.0, 13.0), // 右柱
    ];
    const baseY = 19.0;
    const barR = 1.5; // 柱子圆角

    // 先画柱子
    for (final (x, w, h) in bars) {
      final rect = Rect.fromLTWH(x * s, (baseY - h) * s, w * s, h * s);
      canvas.drawRRect(
        RRect.fromRectAndRadius(rect, Radius.circular(barR * s)),
        barPaint,
      );
    }

    // 每根柱子内部底部嵌一个横向白色长方形（四周留间距）
    const shelfY = 15.5; // 离柱底 2，位于柱子内部底部
    const shelfH = 1.5;
    const shelfR = 0.5;
    const sideGap = 1.0; // 左右内缩，与柱子内壁留间距
    for (final (x, w, _) in bars) {
      final rect = Rect.fromLTWH(
        (x + sideGap) * s,
        shelfY * s,
        (w - sideGap * 2) * s,
        shelfH * s,
      );
      canvas.drawRRect(
        RRect.fromRectAndRadius(rect, Radius.circular(shelfR * s)),
        shelfPaint,
      );
    }
  }

  @override
  bool shouldRepaint(_BookshelfPainter oldDelegate) =>
      oldDelegate.color != color;
}
