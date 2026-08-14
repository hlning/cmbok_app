// 漫画源仓库：启用/禁用源 + 云端配置 URL（本期 stub）。
//
// 顶部输入云端 sources.json URL（持久化，后续接 Dio 拉取）；
// 下方列出所有已注册源，可单独启用/禁用，需要魔法的源标魔法图标。
// 搜索页只展示启用源（见 search_page._buildSourceChips 用 enabledSources）。

import 'package:flutter/material.dart';
import '../services/settings_service.dart';
import '../source/config_manga_source.dart';
import '../source/manga_source.dart';
import '../source/source_config_store.dart';
import '../source/source_manager.dart';
import '../theme/jelly_theme.dart';

class SourceRepoPage extends StatefulWidget {
  const SourceRepoPage({super.key});

  @override
  State<SourceRepoPage> createState() => _SourceRepoPageState();
}

class _SourceRepoPageState extends State<SourceRepoPage> {
  late final TextEditingController _urlCtrl;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _urlCtrl = TextEditingController(text: SettingsService().sourceRepoUrl);
  }

  @override
  void dispose() {
    _urlCtrl.dispose();
    super.dispose();
  }

  void _toast(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text(msg),
          duration: const Duration(seconds: 2),
          behavior: SnackBarBehavior.floating,
        ),
      );
  }

  Future<void> _updateFromCloud() async {
    final url = _urlCtrl.text.trim();
    await SettingsService().setSourceRepoUrl(url);
    if (url.isEmpty) {
      _toast('请先填写云端仓库地址');
      return;
    }
    setState(() => _busy = true);
    try {
      // 本期 fetchRemote 为 stub（返回 null）；云端 URL 已持久化，后续接入 Dio 拉取。
      final remote = await SourceConfigStore().fetchRemote();
      if (remote == null) {
        _toast('云端更新暂未开放，当前使用本地配置');
        return;
      }
      await SourceConfigStore().saveLocal(remote);
      await SourceManager().reload();
      _toast('已从云端更新 ${remote.length} 个源');
    } catch (e) {
      _toast('云端更新失败: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _resetToLocal() async {
    setState(() => _busy = true);
    try {
      await SourceConfigStore().resetToLocal();
      await SourceManager().reload();
      _toast('已恢复本地默认源');
    } catch (e) {
      _toast('恢复失败: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Scaffold(
      appBar: AppBar(title: const Text('漫画源仓库')),
      body: ListenableBuilder(
        listenable: SourceManager(),
        builder: (context, _) {
          final sources = SourceManager().sources;
          return ListView(
            padding: const EdgeInsets.all(16),
            children: [
              _buildCloudCard(isDark),
              const SizedBox(height: 16),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 4),
                child: Text(
                  '已注册源（${sources.length}）· 关闭后不在搜索页显示',
                  style: TextStyle(
                    fontSize: 12,
                    color: JellyTheme.textSecondary,
                  ),
                ),
              ),
              const SizedBox(height: 8),
              for (final s in sources) ...[
                _buildSourceCard(isDark, s),
                const SizedBox(height: 10),
              ],
            ],
          );
        },
      ),
    );
  }

  Widget _buildCloudCard(bool isDark) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: isDark ? JellyTheme.cardDark : JellyTheme.cardLight,
        borderRadius: BorderRadius.circular(16),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '云端仓库',
            style: TextStyle(
              fontSize: 15,
              fontWeight: FontWeight.bold,
              color: isDark ? Colors.white : JellyTheme.textPrimaryLight,
            ),
          ),
          const SizedBox(height: 2),
          Text(
            '填写云端 sources.json 地址，更新后覆盖本地源配置',
            style: TextStyle(fontSize: 12, color: JellyTheme.textSecondary),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _urlCtrl,
            decoration: InputDecoration(
              isDense: true,
              hintText: 'https://example.com/sources.json',
              hintStyle: TextStyle(
                fontSize: 13,
                color: JellyTheme.textSecondary,
              ),
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
              ),
              contentPadding: const EdgeInsets.symmetric(
                horizontal: 12,
                vertical: 10,
              ),
            ),
            style: const TextStyle(fontSize: 13),
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: FilledButton.icon(
                  onPressed: _busy ? null : _updateFromCloud,
                  icon: _busy
                      ? const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.cloud_download_rounded, size: 18),
                  label: const Text('从云端更新'),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: _busy ? null : _resetToLocal,
                  icon: const Icon(Icons.restart_alt_rounded, size: 18),
                  label: const Text('恢复默认'),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildSourceCard(bool isDark, MangaSource src) {
    final enabled = SourceManager().isEnabled(src.id);
    return Container(
      padding: const EdgeInsets.fromLTRB(12, 8, 8, 8),
      decoration: BoxDecoration(
        color: isDark ? JellyTheme.cardDark : JellyTheme.cardLight,
        borderRadius: BorderRadius.circular(16),
      ),
      child: Row(
        children: [
          _buildSourceIcon(src),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Flexible(
                      child: Text(
                        src.name,
                        style: TextStyle(
                          fontSize: 15,
                          fontWeight: FontWeight.bold,
                          color: isDark
                              ? Colors.white
                              : JellyTheme.textPrimaryLight,
                        ),
                      ),
                    ),
                    if (src.needsMagic) ...[
                      const SizedBox(width: 6),
                      Image.asset(
                        'assets/icons/magic_stick.png',
                        width: 14,
                        height: 14,
                      ),
                    ],
                  ],
                ),
                const SizedBox(height: 2),
                Text(
                  src.needsMagic ? '需要魔法（代理/VPN）' : src.id,
                  style: TextStyle(
                    fontSize: 12,
                    color: JellyTheme.textSecondary,
                  ),
                ),
              ],
            ),
          ),
          Switch(
            value: enabled,
            activeThumbColor: JellyTheme.primary,
            onChanged: (v) {
              SourceManager().setEnabled(src.id, v);
            },
          ),
        ],
      ),
    );
  }

  /// 源图标：config 源有 icon URL 用网络图，否则用首字圆形占位。
  Widget _buildSourceIcon(MangaSource src) {
    final String? iconUrl = src is ConfigMangaSource ? src.site.icon : null;
    const size = 40.0;
    if (iconUrl != null && iconUrl.isNotEmpty) {
      return ClipRRect(
        borderRadius: BorderRadius.circular(10),
        child: Image.network(
          iconUrl,
          width: size,
          height: size,
          fit: BoxFit.cover,
          errorBuilder: (_, _, _) => _initialAvatar(src, size),
        ),
      );
    }
    return _initialAvatar(src, size);
  }

  Widget _initialAvatar(MangaSource src, double size) {
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: JellyTheme.primary.withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(10),
      ),
      alignment: Alignment.center,
      child: Text(
        src.name.isNotEmpty ? src.name[0] : '?',
        style: TextStyle(
          fontSize: 18,
          fontWeight: FontWeight.bold,
          color: JellyTheme.primary,
        ),
      ),
    );
  }
}
