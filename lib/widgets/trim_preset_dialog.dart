import 'package:flutter/material.dart';

import '../models/trim_preset.dart';
import '../services/trim_preset_service.dart';
import '../theme/jelly_theme.dart';

/// 预设管理弹窗
///
/// [currentParams] 当前参数，用于"保存当前设置为预设"
/// [onLoad] 加载预设后的回调，返回选中的预设
class TrimPresetDialog extends StatefulWidget {
  final TrimParams currentParams;
  final ValueChanged<TrimPreset> onLoad;

  const TrimPresetDialog({
    super.key,
    required this.currentParams,
    required this.onLoad,
  });

  @override
  State<TrimPresetDialog> createState() => _TrimPresetDialogState();
}

class _TrimPresetDialogState extends State<TrimPresetDialog> {
  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return AlertDialog(
      backgroundColor: isDark ? JellyTheme.cardDark : Colors.white,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      title: const Text('预设管理'),
      content: SizedBox(
        width: double.maxFinite,
        child: ListenableBuilder(
          listenable: TrimPresetService(),
          builder: (context, _) {
            final presets = TrimPresetService().presets;
            if (presets.isEmpty) {
              return SizedBox(
                height: 120,
                child: Center(
                  child: Text(
                    '暂无预设，点击下方按钮保存当前设置',
                    style: TextStyle(
                      color: JellyTheme.textSecondary,
                      fontSize: 13,
                    ),
                  ),
                ),
              );
            }
            return ListView.builder(
              shrinkWrap: true,
              itemCount: presets.length,
              itemBuilder: (context, index) {
                final preset = presets[index];
                return _buildPresetTile(preset, isDark);
              },
            );
          },
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('关闭'),
        ),
        FilledButton.icon(
          onPressed: _saveCurrentAsPreset,
          icon: const Icon(Icons.save_alt, size: 18),
          label: const Text('保存当前设置'),
        ),
      ],
    );
  }

  Widget _buildPresetTile(TrimPreset preset, bool isDark) {
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: isDark
            ? Colors.white.withValues(alpha: 0.05)
            : Colors.black.withValues(alpha: 0.03),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  preset.name,
                  style: TextStyle(
                    fontWeight: FontWeight.bold,
                    fontSize: 14,
                    color: isDark ? Colors.white : JellyTheme.textPrimaryLight,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  '阈值 ${preset.threshold} · 边距 ${preset.padding} · '
                  '放大 ${preset.zoom}% · ${preset.deviceWidth}×${preset.deviceHeight}',
                  style: TextStyle(
                    fontSize: 11,
                    color: JellyTheme.textSecondary,
                  ),
                ),
              ],
            ),
          ),
          TextButton(
            onPressed: () {
              widget.onLoad(preset);
              Navigator.of(context).pop();
            },
            child: const Text('加载'),
          ),
          IconButton(
            icon: const Icon(Icons.delete_outline, size: 20),
            color: JellyTheme.error,
            onPressed: () => _confirmDelete(preset.name),
          ),
        ],
      ),
    );
  }

  Future<void> _saveCurrentAsPreset() async {
    final controller = TextEditingController();
    final result = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor:
            Theme.of(ctx).brightness == Brightness.dark
                ? JellyTheme.cardDark
                : Colors.white,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: const Text('保存预设'),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: const InputDecoration(
            labelText: '预设名称',
            hintText: '请输入预设名称',
            border: OutlineInputBorder(),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(controller.text.trim()),
            child: const Text('保存'),
          ),
        ],
      ),
    );

    if (result == null || result.isEmpty) return;
    if (!mounted) return;

    final preset = TrimPreset(name: result, params: widget.currentParams);
    final ok = await TrimPresetService().addPreset(preset);
    if (!mounted) return;
    if (!ok) {
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(
          const SnackBar(
            content: Text('预设名称已存在，请换一个名称'),
            behavior: SnackBarBehavior.floating,
            duration: Duration(seconds: 2),
          ),
        );
    }
  }

  Future<void> _confirmDelete(String name) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor:
            Theme.of(ctx).brightness == Brightness.dark
                ? JellyTheme.cardDark
                : Colors.white,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: const Text('删除预设'),
        content: Text('确定要删除预设「$name」吗？'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: JellyTheme.error),
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (ok == true) {
      await TrimPresetService().deletePreset(name);
    }
  }
}
