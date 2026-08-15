import 'package:flutter/material.dart';
import '../theme/jelly_theme.dart';

/// HSV 取色器对话框（自建，无第三方依赖）。
///
/// 布局：SV 方块（饱和度×明度）+ 色相滑块 + hex 输入 + 新旧色对比 + 确定/取消。
/// 静态入口 [show] 返回用户选定颜色；取消返回 null。
class ColorPickerDialog extends StatefulWidget {
  final Color initial;
  final String? title;

  const ColorPickerDialog({super.key, required this.initial, this.title});

  /// 弹出取色器；返回选定颜色，取消返回 null。
  static Future<Color?> show(
    BuildContext context, {
    required Color initial,
    String? title,
  }) {
    return showDialog<Color?>(
      context: context,
      builder: (_) => ColorPickerDialog(initial: initial, title: title),
    );
  }

  @override
  State<ColorPickerDialog> createState() => _ColorPickerDialogState();
}

class _ColorPickerDialogState extends State<ColorPickerDialog> {
  late HSVColor _hsv;
  late TextEditingController _hexCtrl;

  static const _squareSize = 220.0;
  static const _hueHeight = 28.0;

  @override
  void initState() {
    super.initState();
    _hsv = HSVColor.fromColor(widget.initial);
    _hexCtrl = TextEditingController(text: _toHex(widget.initial));
  }

  @override
  void dispose() {
    _hexCtrl.dispose();
    super.dispose();
  }

  Color get _color => _hsv.toColor();

  void _setColor(HSVColor hsv) {
    setState(() {
      _hsv = hsv;
      _hexCtrl.text = _toHex(_hsv.toColor());
      _hexCtrl.selection = TextSelection.fromPosition(
        TextPosition(offset: _hexCtrl.text.length),
      );
    });
  }

  // -------------------- SV 方块手势 --------------------
  void _onSquarePan(Offset local, double size) {
    final s = (local.dx / size).clamp(0.0, 1.0);
    final v = (1.0 - local.dy / size).clamp(0.0, 1.0);
    _setColor(_hsv.withSaturation(s).withValue(v));
  }

  // -------------------- 色相滑块手势 --------------------
  void _onHuePan(Offset local, double width) {
    final h = (local.dx / width * 360.0).clamp(0.0, 359.99);
    _setColor(_hsv.withHue(h));
  }

  // -------------------- hex 输入 --------------------
  void _onHexChanged(String v) {
    var s = v.trim();
    if (s.startsWith('#')) s = s.substring(1);
    if (s.length == 6) s = 'FF$s';
    final parsed = int.tryParse(s, radix: 16);
    if (parsed != null) {
      setState(() {
        _hsv = HSVColor.fromColor(Color(parsed));
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final hueColor = HSVColor.fromAHSV(1, _hsv.hue, 1, 1).toColor();
    return Dialog(
      backgroundColor: isDark ? JellyTheme.cardDark : JellyTheme.cardLight,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (widget.title != null)
                Padding(
                  padding: const EdgeInsets.only(bottom: 12),
                  child: Text(
                    widget.title!,
                    style: TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w600,
                      color: isDark
                          ? Colors.white
                          : JellyTheme.textPrimaryLight,
                    ),
                  ),
                ),
              // SV 方块
              Center(
                child: GestureDetector(
                  onPanDown: (d) => _onSquarePan(d.localPosition, _squareSize),
                  onPanUpdate: (d) =>
                      _onSquarePan(d.localPosition, _squareSize),
                  child: SizedBox(
                    width: _squareSize,
                    height: _squareSize,
                    child: Stack(
                      fit: StackFit.expand,
                      children: [
                        ClipRRect(
                          borderRadius: BorderRadius.circular(12),
                          child: Stack(
                            fit: StackFit.expand,
                            children: [
                              ColoredBox(color: hueColor),
                              // 横向：白(左) -> 透明(右)，控制饱和度
                              Container(
                                decoration: const BoxDecoration(
                                  gradient: LinearGradient(
                                    begin: Alignment.centerLeft,
                                    end: Alignment.centerRight,
                                    colors: [
                                      Color(0xFFFFFFFF),
                                      Color(0x00FFFFFF),
                                    ],
                                  ),
                                ),
                              ),
                              // 纵向：透明(上) -> 黑(下)，控制明度
                              Container(
                                decoration: const BoxDecoration(
                                  gradient: LinearGradient(
                                    begin: Alignment.topCenter,
                                    end: Alignment.bottomCenter,
                                    colors: [
                                      Color(0x00000000),
                                      Color(0xFF000000),
                                    ],
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                        // 游标
                        Positioned(
                          left:
                              (_hsv.saturation * _squareSize).clamp(
                                8.0,
                                _squareSize - 8,
                              ) -
                              8,
                          top:
                              ((1 - _hsv.value) * _squareSize).clamp(
                                8.0,
                                _squareSize - 8,
                              ) -
                              8,
                          child: Container(
                            width: 16,
                            height: 16,
                            decoration: BoxDecoration(
                              shape: BoxShape.circle,
                              color: _color,
                              border: Border.all(
                                color: Colors.white,
                                width: 2.5,
                              ),
                              boxShadow: const [
                                BoxShadow(
                                  color: Color(0x66000000),
                                  blurRadius: 4,
                                ),
                              ],
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 14),
              // 色相滑块
              LayoutBuilder(
                builder: (context, constraints) {
                  final w = constraints.maxWidth;
                  return GestureDetector(
                    onPanDown: (d) => _onHuePan(d.localPosition, w),
                    onPanUpdate: (d) => _onHuePan(d.localPosition, w),
                    child: SizedBox(
                      height: _hueHeight,
                      child: Stack(
                        children: [
                          ClipRRect(
                            borderRadius: BorderRadius.circular(6),
                            child: const DecoratedBox(
                              decoration: BoxDecoration(
                                gradient: LinearGradient(
                                  colors: [
                                    Color(0xFFFF0000),
                                    Color(0xFFFFFF00),
                                    Color(0xFF00FF00),
                                    Color(0xFF00FFFF),
                                    Color(0xFF0000FF),
                                    Color(0xFFFF00FF),
                                    Color(0xFFFF0000),
                                  ],
                                ),
                              ),
                              child: SizedBox.expand(),
                            ),
                          ),
                          Positioned(
                            left: (_hsv.hue / 360 * w).clamp(0.0, w - 4) - 4,
                            top: 0,
                            child: Container(
                              width: 8,
                              height: _hueHeight,
                              decoration: BoxDecoration(
                                color: Colors.white,
                                borderRadius: BorderRadius.circular(4),
                                border: Border.all(
                                  color: Colors.black26,
                                  width: 1,
                                ),
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  );
                },
              ),
              const SizedBox(height: 14),
              // hex 输入 + 新旧色对比
              Row(
                children: [
                  _swatch(widget.initial, '原色'),
                  const SizedBox(width: 8),
                  _swatch(_color, '当前'),
                  const SizedBox(width: 12),
                  Expanded(
                    child: TextField(
                      controller: _hexCtrl,
                      onChanged: _onHexChanged,
                      style: TextStyle(
                        fontSize: 14,
                        color: isDark
                            ? Colors.white
                            : JellyTheme.textPrimaryLight,
                      ),
                      decoration: InputDecoration(
                        isDense: true,
                        prefixText: '#',
                        prefixStyle: TextStyle(color: JellyTheme.textSecondary),
                        contentPadding: const EdgeInsets.symmetric(
                          horizontal: 12,
                          vertical: 10,
                        ),
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(10),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              // 操作按钮
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  TextButton(
                    onPressed: () => Navigator.of(context).pop(null),
                    child: Text(
                      '取消',
                      style: TextStyle(color: JellyTheme.textSecondary),
                    ),
                  ),
                  const SizedBox(width: 8),
                  FilledButton(
                    onPressed: () => Navigator.of(context).pop(_color),
                    style: FilledButton.styleFrom(
                      backgroundColor: JellyTheme.primary,
                    ),
                    child: const Text('确定'),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _swatch(Color c, String label) {
    return Column(
      children: [
        Container(
          width: 36,
          height: 36,
          decoration: BoxDecoration(
            color: c,
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: Colors.black12),
          ),
        ),
        const SizedBox(height: 4),
        Text(
          label,
          style: TextStyle(fontSize: 11, color: JellyTheme.textSecondary),
        ),
      ],
    );
  }
}

String _toHex(Color c) =>
    c.toARGB32().toRadixString(16).padLeft(8, '0').toUpperCase().substring(2);
