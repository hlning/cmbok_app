import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../theme/jelly_theme.dart';

/// 生成默认封面图（PNG），供无内嵌封面的本地书（如 txt）使用。
class CoverGenerator {
  CoverGenerator._();

  /// 生成默认封面：渐变背景 + 格式标识，返回 PNG 字节。
  /// [ext] 决定标识与配色：txt（默认）= "TXT 文本图书"（主色紫），
  /// pdf = "PDF 文档"（accent 暖色），便于书架区分无内嵌封面的本地书。
  static Future<Uint8List> generateDefaultCover({
    int width = 300,
    int height = 450,
    String ext = 'txt',
  }) async {
    final isPdf = ext.toLowerCase() == 'pdf';
    final base = isPdf ? JellyTheme.accent : JellyTheme.primary;
    final label = isPdf ? 'PDF' : 'TXT';
    final subLabel = isPdf ? 'PDF 文档' : '文本图书';
    final recorder = ui.PictureRecorder();
    final canvas = ui.Canvas(recorder);
    final w = width.toDouble();
    final h = height.toDouble();

    // 渐变背景
    final bgPaint = ui.Paint()
      ..shader = ui.Gradient.linear(Offset.zero, Offset(w, h), [
        base,
        base.withValues(alpha: 0.55),
      ]);
    canvas.drawRect(Offset.zero & ui.Size(w, h), bgPaint);

    void drawText(String text, double fontSize, double y, ui.Color color) {
      final pb =
          ui.ParagraphBuilder(
              ui.ParagraphStyle(
                textAlign: ui.TextAlign.center,
                fontSize: fontSize,
              ),
            )
            ..pushStyle(
              ui.TextStyle(
                color: color,
                fontSize: fontSize,
                fontWeight: ui.FontWeight.bold,
              ),
            )
            ..addText(text)
            ..pop();
      final p = pb.build()..layout(ui.ParagraphConstraints(width: w));
      canvas.drawParagraph(p, Offset(0, y));
    }

    drawText(label, 44, h / 2 - 55, Colors.white);
    drawText(subLabel, 16, h / 2 + 15, Colors.white.withValues(alpha: 0.85));

    final picture = recorder.endRecording();
    final image = await picture.toImage(width, height);
    final byteData = await image.toByteData(format: ui.ImageByteFormat.png);
    if (byteData == null) throw StateError('默认封面编码失败');
    return byteData.buffer.asUint8List();
  }
}
