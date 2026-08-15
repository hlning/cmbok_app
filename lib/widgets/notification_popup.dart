import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../services/remote_config_service.dart';
import '../theme/jelly_theme.dart';

/// 公告弹窗：首页居中弹出远程公告（同步 Windows 端）。
/// - 显示条件：notification 非空、未被用户关闭、且当前无新版本提示。
/// - 互斥逻辑：有新版本时不弹公告（同步 Windows 端 StartupCheckThread）。
/// - 关闭后相同公告不再弹出；远程刷新出新文本（文本变化）时自动再弹。
/// - 不占布局：build 返回 SizedBox.shrink()，仅在条件满足时弹 Dialog。
class NotificationPopup extends StatefulWidget {
  const NotificationPopup({super.key});

  @override
  State<NotificationPopup> createState() => _NotificationPopupState();
}

class _NotificationPopupState extends State<NotificationPopup> {
  static const _kDismissed = 'dismissed_notification';
  bool _loaded = false; // dismissed 是否已从本地加载完（加载前不弹，避免已关闭公告闪现）
  String _dismissed = ''; // 已关闭的公告文本
  bool _showing = false; // 当前公告弹窗是否已触发（防重复弹）

  @override
  void initState() {
    super.initState();
    RemoteConfigService().addListener(_onConfigChanged);
    _loadDismissed();
  }

  @override
  void dispose() {
    RemoteConfigService().removeListener(_onConfigChanged);
    super.dispose();
  }

  Future<void> _loadDismissed() async {
    final prefs = await SharedPreferences.getInstance();
    final v = prefs.getString(_kDismissed) ?? '';
    if (!mounted) return;
    setState(() {
      _dismissed = v;
      _loaded = true;
    });
    _maybeShow();
  }

  void _onConfigChanged() => _maybeShow();

  /// 满足条件则弹窗：已加载 dismiss 状态、未在弹、公告非空且未关闭、且无新版本。
  void _maybeShow() {
    if (!_loaded || _showing) return;
    // 互斥：有新版本时不弹公告（同步 Windows 端）
    if (RemoteConfigService().hasNewVersion) return;
    final text = RemoteConfigService().notification;
    if (text.isEmpty || text == _dismissed) return;
    setState(() => _showing = true); // 立即占位，防止重复触发
    WidgetsBinding.instance.addPostFrameCallback((_) => _showDialog(text));
  }

  Future<void> _showDialog(String text) async {
    if (!mounted) return;
    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Row(
          children: [
            Icon(Icons.campaign_rounded, color: JellyTheme.primary, size: 22),
            const SizedBox(width: 8),
            const Text('公告'),
          ],
        ),
        content: Text(text, style: const TextStyle(fontSize: 14, height: 1.6)),
        actionsAlignment: MainAxisAlignment.center,
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('知道了'),
          ),
        ],
      ),
    );
    if (!mounted) return;
    setState(() => _showing = false);
    await _dismiss(text);
  }

  Future<void> _dismiss(String notification) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_kDismissed, notification);
    if (!mounted) return;
    setState(() => _dismissed = notification);
  }

  @override
  Widget build(BuildContext context) => const SizedBox.shrink();
}
