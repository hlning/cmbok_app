import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart';
import '../services/settings_service.dart';
import '../theme/jelly_theme.dart';

/// 下载设置页：保存位置 + 同时下载量 + 分片并发量 + 合并 EPUB 开关
class DownloadSettingsPage extends StatelessWidget {
  const DownloadSettingsPage({super.key});

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Scaffold(
      appBar: AppBar(title: const Text('下载设置')),
      body: ListenableBuilder(
        listenable: SettingsService(),
        builder: (context, _) {
          final s = SettingsService();
          return ListView(
            padding: const EdgeInsets.all(16),
            children: [
              _buildSaveLocationCard(context, isDark, s),
              const SizedBox(height: 12),
              _buildCard(
                isDark,
                title: '同时下载量',
                value: s.maxConcurrentChapters,
                min: SettingsService.minConcurrentChapters,
                max: SettingsService.maxConcurrentChaptersLimit,
                subtitle: '允许同时下载的漫画/图书章节数',
                onChanged: (v) => s.setMaxConcurrentChapters(v.round()),
              ),
              const SizedBox(height: 12),
              _buildCard(
                isDark,
                title: '分片并发量',
                value: s.maxConcurrentImages,
                min: SettingsService.minConcurrentImages,
                max: SettingsService.maxConcurrentImagesLimit,
                subtitle: '单个章节同时下载的图片数',
                onChanged: (v) => s.setMaxConcurrentImages(v.round()),
              ),
              const SizedBox(height: 12),
              _buildSwitchCard(
                isDark,
                title: '漫画章节合并为 EPUB',
                subtitle: '章节下载完成后将该章图片合并为一个 .epub 文件',
                value: s.mergeChapterToEpub,
                onChanged: (v) => s.setMergeChapterToEpub(v),
              ),
              const SizedBox(height: 12),
              _buildSwitchCard(
                isDark,
                title: '合并后保留图片',
                subtitle: s.mergeChapterToEpub
                    ? '保留原图用于 App 内离线阅读；关闭则仅保留 EPUB，只能在线阅读'
                    : '需先开启「漫画章节合并为 EPUB」',
                value: s.keepImagesAfterEpub,
                onChanged: s.mergeChapterToEpub
                    ? (v) => s.setKeepImagesAfterEpub(v)
                    : null,
              ),
              const SizedBox(height: 16),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 4),
                child: Text(
                  '提示：同时下载量越大，下载越快但更易触发站点风控；'
                  '分片并发量越大，单章下载越快但更耗带宽。',
                  style: const TextStyle(
                    fontSize: 12,
                    color: JellyTheme.textSecondary,
                  ),
                ),
              ),
            ],
          );
        },
      ),
    );
  }

  /// 保存位置卡片：显示当前路径，可选择目录或恢复默认
  Widget _buildSaveLocationCard(
    BuildContext context,
    bool isDark,
    SettingsService s,
  ) {
    final custom = s.downloadSavePath;
    final hasCustom = custom != null && custom.isNotEmpty;
    final display = hasCustom ? custom : '默认（应用私有目录）';
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 12, 8, 12),
      decoration: BoxDecoration(
        color: isDark ? JellyTheme.cardDark : JellyTheme.cardLight,
        borderRadius: BorderRadius.circular(16),
      ),
      child: Row(
        children: [
          Icon(Icons.folder_rounded, color: JellyTheme.primary, size: 22),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '保存位置',
                  style: TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.bold,
                    color: isDark ? Colors.white : JellyTheme.textPrimaryLight,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  display,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 12,
                    color: JellyTheme.textSecondary,
                  ),
                ),
              ],
            ),
          ),
          if (hasCustom)
            IconButton(
              icon: const Icon(Icons.refresh_rounded, size: 20),
              tooltip: '恢复默认',
              onPressed: () => s.setDownloadSavePath(null),
            ),
          IconButton(
            icon: const Icon(Icons.folder_open_rounded, size: 20),
            tooltip: '选择目录',
            onPressed: () => _pickSavePath(context, s),
          ),
        ],
      ),
    );
  }

  Future<void> _pickSavePath(BuildContext context, SettingsService s) async {
    final path = await FilePicker.platform.getDirectoryPath();
    if (path == null) return; // 用户取消
    if (!context.mounted) return;
    // Android SAF 可能返回 content:// URI，无法用 File 直接写入
    if (path.startsWith('content://')) {
      _toast(context, '该目录暂不可用（Android 内容 URI），请选择文件系统目录或使用默认');
      return;
    }
    // 先直接校验可写；不可写时（多为权限不足）申请存储权限后重试
    if (!await _isWritable(path)) {
      final fixed =
          Platform.isAndroid &&
          await _ensureStoragePermission() &&
          await _isWritable(path);
      if (!context.mounted) return;
      if (!fixed) {
        _toast(
          context,
          Platform.isAndroid
              ? '需要「所有文件访问」权限才能写入该目录，请在系统设置中授权后重试'
              : '该目录不可写，请选择其他目录或使用默认',
        );
        return;
      }
    }
    await s.setDownloadSavePath(path);
    if (!context.mounted) return;
    _toast(context, '保存位置已更新');
  }

  /// 校验目录可写：创建目录（若不存在）并写一个临时探针文件
  Future<bool> _isWritable(String path) async {
    try {
      final dir = Directory(path);
      if (!await dir.exists()) {
        await dir.create(recursive: true);
      }
      final probe = File('${dir.path}/.cmbok_probe');
      await probe.writeAsString('ok');
      await probe.delete();
      return true;
    } catch (_) {
      return false;
    }
  }

  /// Android：请求写入自定义公共目录所需的存储权限
  /// Android 11+ 用「所有文件访问」，旧版本回退普通存储权限。
  Future<bool> _ensureStoragePermission() async {
    if (await Permission.manageExternalStorage.isGranted) return true;
    final r = await Permission.manageExternalStorage.request();
    if (r.isGranted) return true;
    if (await Permission.storage.isGranted) return true;
    final r2 = await Permission.storage.request();
    return r2.isGranted;
  }

  void _toast(BuildContext context, String msg) {
    if (!context.mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text(msg),
          duration: const Duration(seconds: 3),
          behavior: SnackBarBehavior.floating,
        ),
      );
  }

  Widget _buildSwitchCard(
    bool isDark, {
    required String title,
    required String subtitle,
    required bool value,
    required ValueChanged<bool>? onChanged,
  }) {
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 12, 8, 12),
      decoration: BoxDecoration(
        color: isDark ? JellyTheme.cardDark : JellyTheme.cardLight,
        borderRadius: BorderRadius.circular(16),
      ),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.bold,
                    color: isDark ? Colors.white : JellyTheme.textPrimaryLight,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  subtitle,
                  style: const TextStyle(
                    fontSize: 12,
                    color: JellyTheme.textSecondary,
                  ),
                ),
              ],
            ),
          ),
          Switch(
            value: value,
            activeThumbColor: JellyTheme.primary,
            onChanged: onChanged,
          ),
        ],
      ),
    );
  }

  Widget _buildCard(
    bool isDark, {
    required String title,
    required int value,
    required int min,
    required int max,
    required String subtitle,
    required ValueChanged<double> onChanged,
  }) {
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
      decoration: BoxDecoration(
        color: isDark ? JellyTheme.cardDark : JellyTheme.cardLight,
        borderRadius: BorderRadius.circular(16),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text(
                title,
                style: TextStyle(
                  fontSize: 15,
                  fontWeight: FontWeight.bold,
                  color: isDark ? Colors.white : JellyTheme.textPrimaryLight,
                ),
              ),
              const Spacer(),
              Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 10,
                  vertical: 2,
                ),
                decoration: BoxDecoration(
                  color: JellyTheme.primary.withValues(alpha: 0.15),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Text(
                  '$value',
                  style: const TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.bold,
                    color: JellyTheme.primary,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            subtitle,
            style: const TextStyle(
              fontSize: 12,
              color: JellyTheme.textSecondary,
            ),
          ),
          Slider(
            value: value.toDouble(),
            min: min.toDouble(),
            max: max.toDouble(),
            divisions: max - min,
            activeColor: JellyTheme.primary,
            onChanged: onChanged,
          ),
          Row(
            children: [
              Text(
                '$min',
                style: const TextStyle(
                  fontSize: 11,
                  color: JellyTheme.textSecondary,
                ),
              ),
              const Spacer(),
              Text(
                '$max',
                style: const TextStyle(
                  fontSize: 11,
                  color: JellyTheme.textSecondary,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
