import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import '../services/settings_service.dart';
import '../theme/jelly_palette.dart';
import '../theme/theme_background_painters.dart';
import '../widgets/color_picker_dialog.dart';

/// 自定义主题编辑页：命名 + 选基底预设 + 全量 18 色逐项调色 + 保存。
///
/// 保存调用 [SettingsService.addCustomTheme]（新增到自定义列表，不自动选中）。
class CustomThemeEditorPage extends StatefulWidget {
  /// 编辑已有主题时传入；为 null 表示新建。
  final ThemePresetInfo? editing;

  const CustomThemeEditorPage({super.key, this.editing});

  @override
  State<CustomThemeEditorPage> createState() => _CustomThemeEditorPageState();
}

class _CustomThemeEditorPageState extends State<CustomThemeEditorPage> {
  late JellyPalette _working;
  late String _baseId;
  ThemeBackground _workingBg = const ThemeBackground.none(); // 当前编辑中的背景配置
  late final TextEditingController _nameCtrl;

  bool get _isEditing => widget.editing != null;

  @override
  void initState() {
    super.initState();
    final e = widget.editing;
    if (e != null) {
      // 编辑已有：以其调色板/名称/背景初始化（基底不预选——custom id 不匹配预设）
      _baseId = e.id;
      _working = e.palette;
      _workingBg = e.background;
      _nameCtrl = TextEditingController(text: e.name);
    } else {
      // 新建：默认以当前主题为基底
      final current = SettingsService().currentThemeInfo;
      _baseId = current.id;
      _working = current.palette;
      _nameCtrl = TextEditingController(text: '自定义主题');
    }
  }

  @override
  void dispose() {
    _nameCtrl.dispose();
    super.dispose();
  }

  Future<void> _pickColor(_ColorField field) async {
    final result = await ColorPickerDialog.show(
      context,
      initial: field.get(_working),
      title: field.label,
    );
    if (result != null) {
      setState(() => _working = field.set(_working, result));
    }
  }

  Future<void> _save() async {
    final trimmed = _nameCtrl.text.trim();
    final name = trimmed.isEmpty
        ? (_isEditing ? widget.editing!.name : '自定义主题')
        : trimmed;
    if (_isEditing) {
      await SettingsService().updateCustomTheme(
        widget.editing!.id,
        name: name,
        palette: _working,
        background: _workingBg,
      );
    } else {
      await SettingsService().addCustomTheme(
        name: name,
        palette: _working,
        background: _workingBg,
      );
    }
    if (mounted) Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Scaffold(
      backgroundColor: isDark
          ? _working.backgroundDark
          : _working.backgroundLight,
      appBar: AppBar(
        backgroundColor: isDark
            ? _working.backgroundDark
            : _working.backgroundLight,
        title: Text(_isEditing ? '编辑主题' : '自定义主题'),
        actions: [
          IconButton(
            icon: const Icon(Icons.check_rounded),
            tooltip: '保存',
            onPressed: _save,
          ),
        ],
      ),
      body: Stack(
        fit: StackFit.expand,
        children: [
          // 实时背景预览：所选动画/图片铺满编辑区，所见即所得（纯色返回空）
          Positioned.fill(
            child: _BackgroundPreview(
              background: _workingBg,
              palette: _working,
              isDark: isDark,
            ),
          ),
          ListView(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
            children: [
              // 名称
              _buildNameField(isDark),
              const SizedBox(height: 16),
              // 预览
              _buildPreview(isDark),
              const SizedBox(height: 16),
              // 基底预设
              _buildBaseSelector(isDark),
              const SizedBox(height: 16),
              // 背景（纯色 / 内置动画 / 图片）
              _buildBackgroundSection(isDark),
              const SizedBox(height: 16),
              // 分组颜色列表
              ..._buildColorSections(isDark),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildNameField(bool isDark) {
    return TextField(
      controller: _nameCtrl,
      decoration: InputDecoration(
        labelText: '主题名称',
        labelStyle: TextStyle(color: _working.textSecondary),
        filled: true,
        fillColor: isDark ? _working.cardDark : _working.cardLight,
        border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
      ),
      style: TextStyle(
        color: isDark ? _working.textPrimaryDark : _working.textPrimaryLight,
      ),
    );
  }

  Widget _buildPreview(bool isDark) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: isDark ? _working.cardDark : _working.cardLight,
        borderRadius: BorderRadius.circular(16),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '预览效果',
            style: TextStyle(fontSize: 13, color: _working.textSecondary),
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '标题文字',
                      style: TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.bold,
                        color: isDark
                            ? _working.textPrimaryDark
                            : _working.textPrimaryLight,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      '次要说明文字',
                      style: TextStyle(
                        fontSize: 13,
                        color: _working.textSecondary,
                      ),
                    ),
                  ],
                ),
              ),
              Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 8,
                ),
                decoration: BoxDecoration(
                  color: _working.primary,
                  borderRadius: BorderRadius.circular(20),
                ),
                child: Text(
                  '按钮',
                  style: TextStyle(color: Colors.white, fontSize: 13),
                ),
              ),
              const SizedBox(width: 10),
              Container(
                width: 28,
                height: 28,
                decoration: BoxDecoration(
                  color: _working.accent,
                  shape: BoxShape.circle,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildBaseSelector(bool isDark) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(left: 4, bottom: 8),
          child: Text(
            '基底预设（点击覆盖当前所有颜色）',
            style: TextStyle(fontSize: 13, color: _working.textSecondary),
          ),
        ),
        SizedBox(
          height: 64,
          child: ListView.separated(
            scrollDirection: Axis.horizontal,
            itemCount: themePresets.length,
            separatorBuilder: (_, _) => const SizedBox(width: 10),
            itemBuilder: (_, i) {
              final p = themePresets[i];
              final selected = p.id == _baseId;
              return GestureDetector(
                onTap: () => setState(() {
                  _baseId = p.id;
                  _working = p.palette;
                }),
                child: Column(
                  children: [
                    Container(
                      width: 40,
                      height: 40,
                      decoration: BoxDecoration(
                        color: p.palette.primary,
                        shape: BoxShape.circle,
                        border: Border.all(
                          color: selected
                              ? _working.primary
                              : Colors.transparent,
                          width: 3,
                        ),
                        boxShadow: [
                          BoxShadow(
                            color: p.palette.primary.withValues(alpha: 0.3),
                            blurRadius: 6,
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      p.name,
                      style: TextStyle(
                        fontSize: 11,
                        color: selected
                            ? (isDark
                                  ? _working.textPrimaryDark
                                  : _working.textPrimaryLight)
                            : _working.textSecondary,
                      ),
                    ),
                  ],
                ),
              );
            },
          ),
        ),
      ],
    );
  }

  List<Widget> _buildColorSections(bool isDark) {
    return _sections.map((section) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(left: 4, top: 8, bottom: 6),
            child: Text(
              section.title,
              style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w600,
                color: _working.textSecondary,
              ),
            ),
          ),
          Container(
            decoration: BoxDecoration(
              color: isDark ? _working.cardDark : _working.cardLight,
              borderRadius: BorderRadius.circular(12),
            ),
            child: Column(
              children: [
                for (var i = 0; i < section.fields.length; i++) ...[
                  _buildColorRow(section.fields[i], isDark),
                  if (i < section.fields.length - 1)
                    Divider(
                      height: 1,
                      indent: 56,
                      color: (isDark ? Colors.white : Colors.black).withValues(
                        alpha: 0.06,
                      ),
                    ),
                ],
              ],
            ),
          ),
          const SizedBox(height: 12),
        ],
      );
    }).toList();
  }

  Widget _buildColorRow(_ColorField field, bool isDark) {
    final c = field.get(_working);
    return ListTile(
      onTap: () => _pickColor(field),
      dense: true,
      contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 2),
      leading: Container(
        width: 32,
        height: 32,
        decoration: BoxDecoration(
          color: c,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: Colors.black12),
        ),
      ),
      title: Text(
        field.label,
        style: TextStyle(
          fontSize: 14,
          color: isDark ? _working.textPrimaryDark : _working.textPrimaryLight,
        ),
      ),
      trailing: Icon(
        Icons.chevron_right_rounded,
        color: _working.textSecondary,
        size: 20,
      ),
    );
  }

  // -------------------- 背景（纯色 / 内置动画 / 图片）--------------------

  Widget _buildBackgroundSection(bool isDark) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(left: 4, bottom: 8),
          child: Text(
            '背景',
            style: TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w600,
              color: _working.textSecondary,
            ),
          ),
        ),
        Container(
          decoration: BoxDecoration(
            color: isDark ? _working.cardDark : _working.cardLight,
            borderRadius: BorderRadius.circular(12),
          ),
          child: Column(
            children: [
              _buildBgTypeTile(
                isDark,
                ThemeBackgroundType.none,
                '纯色',
                Icons.format_color_fill_rounded,
              ),
              _sectionDivider(isDark),
              _buildBgTypeTile(
                isDark,
                ThemeBackgroundType.animation,
                '内置动画',
                Icons.auto_awesome_rounded,
              ),
              if (_workingBg.type == ThemeBackgroundType.animation)
                _buildAnimationPicker(isDark),
              _sectionDivider(isDark),
              _buildBgTypeTile(
                isDark,
                ThemeBackgroundType.image,
                '自定义图片',
                Icons.image_rounded,
              ),
              if (_workingBg.type == ThemeBackgroundType.image)
                _buildImagePicker(isDark),
            ],
          ),
        ),
      ],
    );
  }

  /// 背景类型单选行（互斥三选一）。切换类型时保留各自的 animationId/imagePath，
  /// 便于来回切换不丢已选项；首次选「内置动画」默认 green。
  Widget _buildBgTypeTile(
    bool isDark,
    ThemeBackgroundType type,
    String label,
    IconData icon,
  ) {
    final selected = _workingBg.type == type;
    return ListTile(
      onTap: () => setState(() {
        _workingBg = ThemeBackground(
          type: type,
          animationId: type == ThemeBackgroundType.animation
              ? (_workingBg.animationId ?? 'green')
              : _workingBg.animationId,
          imagePath: _workingBg.imagePath,
        );
      }),
      dense: true,
      contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 2),
      leading: Icon(
        icon,
        color: selected ? _working.primary : _working.textSecondary,
        size: 22,
      ),
      title: Text(
        label,
        style: TextStyle(
          fontSize: 14,
          color: isDark ? _working.textPrimaryDark : _working.textPrimaryLight,
        ),
      ),
      trailing: Icon(
        selected
            ? Icons.radio_button_checked_rounded
            : Icons.radio_button_unchecked_rounded,
        color: selected ? _working.primary : _working.textSecondary,
        size: 22,
      ),
    );
  }

  /// 内置动画 6 选 1（借用某套内置背景动画，颜色随本主题调色板）。
  Widget _buildAnimationPicker(bool isDark) {
    return Padding(
      padding: const EdgeInsets.only(left: 50, right: 12, bottom: 8),
      child: SizedBox(
        height: 58,
        child: ListView.separated(
          scrollDirection: Axis.horizontal,
          itemCount: themePresets.length,
          separatorBuilder: (_, _) => const SizedBox(width: 12),
          itemBuilder: (_, i) {
            final p = themePresets[i];
            final selected = p.id == _workingBg.animationId;
            return GestureDetector(
              onTap: () => setState(() {
                _workingBg = ThemeBackground(
                  type: ThemeBackgroundType.animation,
                  animationId: p.id,
                  imagePath: _workingBg.imagePath,
                );
              }),
              child: Column(
                children: [
                  Container(
                    width: 38,
                    height: 38,
                    decoration: BoxDecoration(
                      color: p.palette.primary,
                      shape: BoxShape.circle,
                      border: Border.all(
                        color: selected ? _working.primary : Colors.transparent,
                        width: 3,
                      ),
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    p.name,
                    style: TextStyle(
                      fontSize: 10,
                      color: selected
                          ? (isDark
                                ? _working.textPrimaryDark
                                : _working.textPrimaryLight)
                          : _working.textSecondary,
                    ),
                  ),
                ],
              ),
            );
          },
        ),
      ),
    );
  }

  /// 自定义图片：缩略图 + 选择/更换/移除。
  Widget _buildImagePicker(bool isDark) {
    final hasImg = _workingBg.imagePath != null;
    return Padding(
      padding: const EdgeInsets.only(left: 50, right: 12, bottom: 8),
      child: Row(
        children: [
          if (hasImg) ...[
            ClipRRect(
              borderRadius: BorderRadius.circular(8),
              child: Image.file(
                File(_workingBg.imagePath!),
                width: 56,
                height: 56,
                fit: BoxFit.cover,
                errorBuilder: (_, _, _) => Container(
                  width: 56,
                  height: 56,
                  color: _working.textSecondary.withValues(alpha: 0.2),
                  child: Icon(
                    Icons.broken_image_rounded,
                    color: _working.textSecondary,
                  ),
                ),
              ),
            ),
            const SizedBox(width: 10),
          ],
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  hasImg ? '已选择图片' : '选择一张图片作为背景',
                  style: TextStyle(fontSize: 12, color: _working.textSecondary),
                ),
                const SizedBox(height: 6),
                Wrap(
                  spacing: 8,
                  runSpacing: 6,
                  children: [
                    _buildBgChip(
                      hasImg ? '更换' : '选择图片',
                      Icons.add_photo_alternate_rounded,
                      _pickImage,
                    ),
                    if (hasImg)
                      _buildBgChip(
                        '移除',
                        Icons.delete_outline_rounded,
                        () => setState(() {
                          _workingBg = ThemeBackground(
                            type: ThemeBackgroundType.image,
                            animationId: _workingBg.animationId,
                            imagePath: null,
                          );
                        }),
                      ),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildBgChip(String label, IconData icon, VoidCallback onTap) {
    return ActionChip(
      avatar: Icon(icon, size: 16, color: _working.primary),
      label: Text(
        label,
        style: TextStyle(fontSize: 12, color: _working.primary),
      ),
      onPressed: onTap,
      backgroundColor: Colors.transparent,
      side: BorderSide(color: _working.primary.withValues(alpha: 0.5)),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
      visualDensity: VisualDensity.compact,
      materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
    );
  }

  /// 选图（FileType.custom + 扩展名，部分 ROM 的 SAF 兼容，同书架/字体导入）。
  Future<void> _pickImage() async {
    final result = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowMultiple: false,
      allowedExtensions: const ['jpg', 'jpeg', 'png', 'webp', 'bmp', 'gif'],
    );
    if (result == null || result.files.isEmpty) return;
    final path = result.files.single.path;
    if (path == null) return;
    setState(() {
      _workingBg = ThemeBackground(
        type: ThemeBackgroundType.image,
        animationId: _workingBg.animationId,
        imagePath: path,
      );
    });
  }

  Widget _sectionDivider(bool isDark) => Divider(
    height: 1,
    indent: 50,
    color: (isDark ? Colors.white : Colors.black).withValues(alpha: 0.06),
  );
}

/// 编辑页全屏背景预览：随背景配置实时画动画/图片（纯色返回空，透出 Scaffold 底色）。
/// 动画用独立 [AnimationController] 驱动（仅 animation 类型 repeat），与正式渲染层一致。
class _BackgroundPreview extends StatefulWidget {
  const _BackgroundPreview({
    required this.background,
    required this.palette,
    required this.isDark,
  });

  final ThemeBackground background;
  final JellyPalette palette;
  final bool isDark;

  @override
  State<_BackgroundPreview> createState() => _BackgroundPreviewState();
}

class _BackgroundPreviewState extends State<_BackgroundPreview>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 16),
    );
    if (widget.background.type == ThemeBackgroundType.animation) {
      _ctrl.repeat();
    }
  }

  @override
  void didUpdateWidget(covariant _BackgroundPreview oldWidget) {
    super.didUpdateWidget(oldWidget);
    final animating = widget.background.type == ThemeBackgroundType.animation;
    if (animating && !_ctrl.isAnimating) {
      _ctrl.repeat();
    } else if (!animating && _ctrl.isAnimating) {
      _ctrl.stop();
    }
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    switch (widget.background.type) {
      case ThemeBackgroundType.image:
        final p = widget.background.imagePath;
        if (p == null) return const SizedBox.shrink();
        return Stack(
          fit: StackFit.expand,
          children: [
            Image.file(
              File(p),
              fit: BoxFit.cover,
              width: double.infinity,
              height: double.infinity,
              gaplessPlayback: true,
              errorBuilder: (_, _, _) => const SizedBox.shrink(),
            ),
            ColoredBox(
              color: widget.isDark
                  ? Colors.black.withValues(alpha: 0.45)
                  : Colors.black.withValues(alpha: 0.22),
            ),
          ],
        );
      case ThemeBackgroundType.animation:
        final id = widget.background.animationId;
        if (id == null) return const SizedBox.shrink();
        final painter = backgroundPainterFor(
          id,
          _ctrl,
          widget.isDark,
          widget.palette,
        );
        if (painter == null) return const SizedBox.shrink();
        return RepaintBoundary(
          child: CustomPaint(painter: painter, child: const SizedBox.expand()),
        );
      case ThemeBackgroundType.none:
        return const SizedBox.shrink();
    }
  }
}

/// 一个可调色字段：标签 + 取色 + 设色（copyWith 包装）。
class _ColorField {
  final String label;
  final Color Function(JellyPalette) get;
  final JellyPalette Function(JellyPalette, Color) set;
  const _ColorField(this.label, this.get, this.set);
}

class _ColorSection {
  final String title;
  final List<_ColorField> fields;
  const _ColorSection(this.title, this.fields);
}

// 全量 18 色，按用途分组。set 用 copyWith 覆盖单字段。
final List<_ColorSection> _sections = [
  _ColorSection('主色调', [
    _ColorField('主色', (p) => p.primary, (p, c) => p.copyWith(primary: c)),
    _ColorField(
      '主色浅',
      (p) => p.primaryLight,
      (p, c) => p.copyWith(primaryLight: c),
    ),
    _ColorField(
      '主色深',
      (p) => p.primaryDark,
      (p, c) => p.copyWith(primaryDark: c),
    ),
  ]),
  _ColorSection('辅助色', [
    _ColorField('强调色', (p) => p.accent, (p, c) => p.copyWith(accent: c)),
    _ColorField('成功', (p) => p.success, (p, c) => p.copyWith(success: c)),
    _ColorField('警告', (p) => p.warning, (p, c) => p.copyWith(warning: c)),
    _ColorField('错误', (p) => p.error, (p, c) => p.copyWith(error: c)),
    _ColorField('蓝色标记', (p) => p.blue, (p, c) => p.copyWith(blue: c)),
  ]),
  _ColorSection('背景色', [
    _ColorField(
      '浅色背景',
      (p) => p.backgroundLight,
      (p, c) => p.copyWith(backgroundLight: c),
    ),
    _ColorField(
      '深色背景',
      (p) => p.backgroundDark,
      (p, c) => p.copyWith(backgroundDark: c),
    ),
    _ColorField('浅色卡片', (p) => p.cardLight, (p, c) => p.copyWith(cardLight: c)),
    _ColorField('深色卡片', (p) => p.cardDark, (p, c) => p.copyWith(cardDark: c)),
  ]),
  _ColorSection('导航栏', [
    _ColorField(
      '选中背景',
      (p) => p.navSelectedBg,
      (p, c) => p.copyWith(navSelectedBg: c),
    ),
    _ColorField(
      '选中前景',
      (p) => p.navSelectedFg,
      (p, c) => p.copyWith(navSelectedFg: c),
    ),
    _ColorField(
      '未选中',
      (p) => p.navUnselected,
      (p, c) => p.copyWith(navUnselected: c),
    ),
  ]),
  _ColorSection('文字色', [
    _ColorField(
      '浅色文字',
      (p) => p.textPrimaryLight,
      (p, c) => p.copyWith(textPrimaryLight: c),
    ),
    _ColorField(
      '深色文字',
      (p) => p.textPrimaryDark,
      (p, c) => p.copyWith(textPrimaryDark: c),
    ),
    _ColorField(
      '次要文字',
      (p) => p.textSecondary,
      (p, c) => p.copyWith(textSecondary: c),
    ),
  ]),
];
