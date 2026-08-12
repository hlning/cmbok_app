import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import '../models/peer_device.dart';
import '../models/transfer_offer.dart';
import '../services/book_download_service.dart';
import '../services/peer_transfer_service.dart';
import '../services/settings_service.dart';
import '../theme/jelly_theme.dart';

/// 跨设备传书页面。send=把书发到电脑；receive=接收电脑传来的书。
enum PeerTransferMode { send, receive }

enum _SendStage { source, review, peer, sending }

/// 已选待发文件：path + 展示标题/副标题。
class _PickedFile {
  const _PickedFile({required this.path, required this.title, this.subtitle});
  final String path;
  final String title;
  final String? subtitle;
}

class PeerTransferPage extends StatefulWidget {
  const PeerTransferPage({super.key, required this.mode});
  final PeerTransferMode mode;

  @override
  State<PeerTransferPage> createState() => _PeerTransferPageState();
}

class _PeerTransferPageState extends State<PeerTransferPage> {
  // ---- send ----
  _SendStage _stage = _SendStage.source;
  final List<_PickedFile> _picked = [];
  bool _sendDone = false;
  bool _sendOk = false;
  int _sent = 0, _total = 0, _fileIdx = 0, _fileCount = 0;

  // ---- receive ----
  String? _defaultReceiveDir;
  String? _chosenReceiveDir; // 用户在本页内选过的接收目录（记住给后续邀约）
  bool _receiveStarting = false;
  final List<String> _events = [];

  @override
  void initState() {
    super.initState();
    if (widget.mode == PeerTransferMode.receive) {
      _initReceive();
    }
  }

  /// 只算默认接收目录并挂上邀约回调；不自动开服务，由用户手动开关。
  Future<void> _initReceive() async {
    final base = await SettingsService.downloadBaseDir();
    _defaultReceiveDir = '${base.path}/transfer';
    PeerTransferService().onIncomingOffer = _onIncomingOffer;
    PeerTransferService().onReceiveEvent = _onReceiveEvent;
    if (mounted) setState(() {});
  }

  void _onReceiveEvent(String message) {
    if (!mounted) return;
    setState(() => _events.insert(0, message));
  }

  Future<void> _toggleReceive() async {
    if (PeerTransferService().isReceiving) {
      await PeerTransferService().exitReceiveMode();
      if (!mounted) return;
      setState(() {
        _events.insert(0, '已停止接收');
      });
      return;
    }
    setState(() => _receiveStarting = true);
    final ok = await PeerTransferService().enterReceiveMode();
    if (!mounted) return;
    setState(() {
      _receiveStarting = false;
      _events.insert(0, ok ? '已开启接收，等待电脑传书…' : '启动接收失败，请重试');
    });
  }

  void _onIncomingOffer(TransferOffer offer) {
    if (!mounted) return;
    _showAcceptSheet(offer);
  }

  @override
  void dispose() {
    if (widget.mode == PeerTransferMode.receive) {
      PeerTransferService().onIncomingOffer = null;
      PeerTransferService().onReceiveEvent = null;
      if (PeerTransferService().isReceiving) {
        PeerTransferService().exitReceiveMode();
      }
    } else {
      PeerTransferService().exitSendMode();
    }
    super.dispose();
  }

  // ===================== 发送 =====================

  void _addPicked(List<_PickedFile> newOnes) {
    final existing = _picked.map((p) => p.path).toSet();
    for (final p in newOnes) {
      if (!existing.contains(p.path)) {
        _picked.add(p);
        existing.add(p.path);
      }
    }
  }

  Future<void> _pickFromShelf() async {
    final picked = await showModalBottomSheet<List<_PickedFile>>(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      builder: (_) => const _ShelfPickSheet(),
    );
    if (picked == null || picked.isEmpty) {
      _backToReviewIfAny();
      return;
    }
    _addPicked(picked);
    setState(() => _stage = _SendStage.review);
  }

  Future<void> _pickFromFiles() async {
    final result = await FilePicker.platform.pickFiles(
      allowMultiple: true,
      type: FileType.custom,
      allowedExtensions: const ['epub', 'txt', 'pdf', 'mobi', 'azw', 'azw3'],
    );
    if (result == null || result.files.isEmpty) {
      _backToReviewIfAny();
      return;
    }
    final picked = result.files
        .where((f) => f.path != null)
        .map(
          (f) => _PickedFile(
            path: f.path!,
            title: f.name,
            subtitle: _extLabel(f.name),
          ),
        )
        .toList();
    _addPicked(picked);
    setState(() => _stage = _SendStage.review);
  }

  /// 取消挑选时若已有书，回到审阅步而非停留在来源页。
  void _backToReviewIfAny() {
    if (_picked.isNotEmpty) setState(() => _stage = _SendStage.review);
  }

  void _removePicked(int index) {
    setState(() {
      _picked.removeAt(index);
      if (_picked.isEmpty) _stage = _SendStage.source;
    });
  }

  Future<void> _enterPeerStage() async {
    await PeerTransferService().enterSendMode();
    if (!mounted) return;
    setState(() => _stage = _SendStage.peer);
  }

  Future<void> _onPeerTapped(PeerDevice peer) async {
    // 先探活：mDNS 缓存可能残留已下线设备，直连会失败
    final reachable = await _checkPeerReachable(peer);
    if (!mounted) return;
    if (!reachable) {
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(
          const SnackBar(
            content: Text('设备无响应，请确认电脑已开启「从手机接收」'),
            duration: Duration(seconds: 2),
            behavior: SnackBarBehavior.floating,
          ),
        );
      return;
    }
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('确认发送'),
        content: Text('发送 ${_picked.length} 本书到「${peer.name}」？'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('发送'),
          ),
        ],
      ),
    );
    if (ok == true) _startSend(peer);
  }

  /// 探活对端，期间显示「正在连接设备…」；不可达则服务侧标记离线。
  Future<bool> _checkPeerReachable(PeerDevice peer) async {
    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) => PopScope(
        canPop: false,
        child: const Dialog(
          child: Padding(
            padding: EdgeInsets.all(20),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                SizedBox(
                  width: 24,
                  height: 24,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
                SizedBox(width: 16),
                Text('正在连接设备…'),
              ],
            ),
          ),
        ),
      ),
    );
    final reachable = await PeerTransferService().checkPeerReachable(peer.id);
    if (mounted) Navigator.of(context).pop();
    return reachable;
  }

  Future<void> _startSend(PeerDevice peer) async {
    setState(() {
      _stage = _SendStage.sending;
      _sendDone = false;
      _sendOk = false;
      _sent = _total = _fileIdx = _fileCount = 0;
    });
    final paths = _picked.map((p) => p.path).toList();
    final offerId = await PeerTransferService().sendToPeer(
      peer.id,
      paths,
      onProgress: (sent, total, fileIndex, fileCount) {
        if (!mounted) return;
        setState(() {
          _sent = sent;
          _total = total;
          _fileIdx = fileIndex;
          _fileCount = fileCount;
        });
      },
    );
    if (!mounted) return;
    setState(() {
      _sendDone = true;
      _sendOk = offerId != null;
    });
  }

  // ===================== 接收 =====================

  void _showAcceptSheet(TransferOffer offer) {
    String? dir = _chosenReceiveDir;
    final defaultDir = _defaultReceiveDir ?? '';
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      builder: (ctx) {
        return StatefulBuilder(
          builder: (ctx, setSt) {
            final isDark = Theme.of(ctx).brightness == Brightness.dark;
            return Container(
              decoration: BoxDecoration(
                color: isDark ? const Color(0xFF1E1E3A) : Colors.white,
                borderRadius: const BorderRadius.vertical(
                  top: Radius.circular(24),
                ),
              ),
              child: SafeArea(
                top: false,
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(20, 12, 20, 16),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Center(child: _dragHandle(isDark)),
                      const SizedBox(height: 12),
                      Text(
                        '${offer.peerName} 正在传书给你',
                        style: const TextStyle(
                          fontSize: 17,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        '${offer.fileCount} 个文件 · ${_fmtSize(offer.totalSize)}',
                        style: TextStyle(
                          fontSize: 13,
                          color: isDark
                              ? Colors.white60
                              : JellyTheme.textSecondary,
                        ),
                      ),
                      const SizedBox(height: 12),
                      if (offer.kind == 'book')
                        Padding(
                          padding: const EdgeInsets.only(bottom: 8),
                          child: Text(
                            '书将自动入库到「本地图书」书架；非书文件存到接收目录',
                            style: TextStyle(
                              fontSize: 12,
                              color: isDark ? Colors.white38 : Colors.black45,
                            ),
                          ),
                        ),
                      // 接收目录选择
                      InkWell(
                        borderRadius: BorderRadius.circular(12),
                        onTap: () async {
                          final d = await FilePicker.platform
                              .getDirectoryPath();
                          if (d != null) setSt(() => dir = d);
                        },
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 14,
                            vertical: 12,
                          ),
                          decoration: BoxDecoration(
                            color: isDark
                                ? Colors.white.withValues(alpha: 0.06)
                                : Colors.black.withValues(alpha: 0.04),
                            borderRadius: BorderRadius.circular(12),
                          ),
                          child: Row(
                            children: [
                              Icon(
                                Icons.folder_outlined,
                                size: 20,
                                color: JellyTheme.primary,
                              ),
                              const SizedBox(width: 8),
                              Expanded(
                                child: Text(
                                  dir ?? defaultDir,
                                  style: const TextStyle(fontSize: 13),
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                              const Icon(Icons.chevron_right_rounded, size: 20),
                            ],
                          ),
                        ),
                      ),
                      const SizedBox(height: 16),
                      Row(
                        mainAxisAlignment: MainAxisAlignment.end,
                        children: [
                          TextButton(
                            onPressed: () {
                              Navigator.pop(ctx);
                              _respond(offer, false, null);
                            },
                            child: const Text('拒绝'),
                          ),
                          const SizedBox(width: 8),
                          FilledButton(
                            onPressed: () {
                              Navigator.pop(ctx);
                              _respond(offer, true, dir);
                            },
                            child: const Text('接收'),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
            );
          },
        );
      },
    );
  }

  Future<void> _respond(TransferOffer offer, bool accept, String? dir) async {
    if (accept && dir != null) _chosenReceiveDir = dir;
    await PeerTransferService().respondToOffer(
      offer.id,
      accept: accept,
      dir: accept ? (dir ?? _defaultReceiveDir) : null,
    );
    if (!mounted) return;
    setState(() {
      _events.insert(
        0,
        accept
            ? '正在接收 ${offer.peerName} 的 ${offer.fileCount} 个文件…'
            : '已拒绝 ${offer.peerName} 的传书',
      );
    });
  }

  // ===================== build =====================

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return PopScope(
      canPop:
          widget.mode == PeerTransferMode.receive ||
          _stage == _SendStage.source ||
          (_stage == _SendStage.sending && _sendDone),
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) return;
        _handleBack();
      },
      child: Scaffold(
        backgroundColor: isDark
            ? JellyTheme.backgroundDark
            : JellyTheme.backgroundLight,
        appBar: AppBar(
          title: Text(widget.mode == PeerTransferMode.send ? '传书到电脑' : '从电脑接收'),
          backgroundColor: Colors.transparent,
          elevation: 0,
        ),
        body: widget.mode == PeerTransferMode.send
            ? _buildSend()
            : _buildReceive(),
      ),
    );
  }

  /// 返回键处理：对端页->审阅页->源页；发送中（未完成）忽略。
  void _handleBack() {
    if (_stage == _SendStage.peer) {
      setState(() => _stage = _SendStage.review);
    } else if (_stage == _SendStage.review) {
      setState(() => _stage = _SendStage.source);
    }
  }

  Widget _buildSend() {
    switch (_stage) {
      case _SendStage.source:
        return _buildSource();
      case _SendStage.review:
        return _buildReview();
      case _SendStage.peer:
        return _buildPeer();
      case _SendStage.sending:
        return _buildSending();
    }
  }

  Widget _buildSource() {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const SizedBox(height: 8),
          Text(
            '选择发送方式',
            style: TextStyle(
              fontSize: 15,
              fontWeight: FontWeight.w600,
              color: JellyTheme.primary,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            '请确保手机与电脑在同一局域网（Wi-Fi）',
            style: TextStyle(
              fontSize: 12,
              color: isDark ? Colors.white54 : JellyTheme.textSecondary,
            ),
          ),
          const SizedBox(height: 16),
          _optionCard(
            icon: Icons.library_books_outlined,
            title: '书架传书',
            subtitle: '从已下载 / 本地导入的书中选择',
            onTap: _pickFromShelf,
          ),
          const SizedBox(height: 12),
          _optionCard(
            icon: Icons.folder_open_outlined,
            title: '打开文件管理',
            subtitle: '从文件系统选择书籍文件',
            onTap: _pickFromFiles,
          ),
        ],
      ),
    );
  }

  Widget _optionCard({
    required IconData icon,
    required String title,
    required String subtitle,
    required VoidCallback onTap,
  }) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Material(
      color: isDark ? JellyTheme.cardDark : JellyTheme.cardLight,
      borderRadius: BorderRadius.circular(16),
      elevation: 2,
      shadowColor: Colors.black.withValues(alpha: isDark ? 0.4 : 0.08),
      child: InkWell(
        borderRadius: BorderRadius.circular(16),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Row(
            children: [
              Container(
                width: 44,
                height: 44,
                decoration: BoxDecoration(
                  color: JellyTheme.primary.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Icon(icon, color: JellyTheme.primary, size: 22),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      style: const TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      subtitle,
                      style: TextStyle(
                        fontSize: 12,
                        color: isDark
                            ? Colors.white54
                            : JellyTheme.textSecondary,
                      ),
                    ),
                  ],
                ),
              ),
              const Icon(Icons.chevron_right_rounded, color: Colors.grey),
            ],
          ),
        ),
      ),
    );
  }

  /// 已选清单：列出书名（可删），确认后选择接收设备。
  Widget _buildReview() {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Column(
      children: [
        Container(
          width: double.infinity,
          margin: const EdgeInsets.fromLTRB(16, 8, 16, 8),
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
          decoration: BoxDecoration(
            color: JellyTheme.primary.withValues(alpha: 0.1),
            borderRadius: BorderRadius.circular(12),
          ),
          child: Text(
            '已选 ${_picked.length} 本，确认无误后选择接收设备',
            style: TextStyle(
              fontSize: 13,
              color: JellyTheme.primary,
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
        Expanded(
          child: _picked.isEmpty
              ? const Center(child: Text('未选择书'))
              : ListView.separated(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 16,
                    vertical: 8,
                  ),
                  itemCount: _picked.length,
                  separatorBuilder: (_, _) => const SizedBox(height: 8),
                  itemBuilder: (ctx, i) {
                    final f = _picked[i];
                    return Material(
                      color: isDark
                          ? JellyTheme.cardDark
                          : JellyTheme.cardLight,
                      borderRadius: BorderRadius.circular(14),
                      elevation: 1,
                      child: ListTile(
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(14),
                        ),
                        leading: Container(
                          width: 40,
                          height: 40,
                          decoration: BoxDecoration(
                            color: JellyTheme.primary.withValues(alpha: 0.12),
                            borderRadius: BorderRadius.circular(10),
                          ),
                          child: const Icon(
                            Icons.menu_book_outlined,
                            color: JellyTheme.primary,
                          ),
                        ),
                        title: Text(
                          f.title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(fontWeight: FontWeight.w500),
                        ),
                        subtitle: (f.subtitle == null || f.subtitle!.isEmpty)
                            ? null
                            : Text(
                                f.subtitle!,
                                style: const TextStyle(fontSize: 12),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                        trailing: IconButton(
                          tooltip: '移除',
                          icon: const Icon(Icons.close_rounded, size: 20),
                          onPressed: () => _removePicked(i),
                        ),
                      ),
                    );
                  },
                ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
          child: Row(
            children: [
              OutlinedButton.icon(
                onPressed: () => setState(() => _stage = _SendStage.source),
                icon: const Icon(Icons.add_rounded, size: 18),
                label: const Text('添加'),
              ),
              const Spacer(),
              OutlinedButton.icon(
                onPressed: _picked.isEmpty
                    ? null
                    : () => setState(() {
                        _picked.clear();
                        _stage = _SendStage.source;
                      }),
                icon: const Icon(Icons.delete_sweep_outlined, size: 18),
                label: const Text('清除'),
              ),
              const Spacer(),
              FilledButton.icon(
                onPressed: _picked.isEmpty ? null : _enterPeerStage,
                icon: const Icon(Icons.send_rounded, size: 18),
                label: const Text('选择设备'),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildPeer() {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Column(
      children: [
        Container(
          width: double.infinity,
          margin: const EdgeInsets.fromLTRB(16, 8, 16, 8),
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
          decoration: BoxDecoration(
            color: JellyTheme.primary.withValues(alpha: 0.1),
            borderRadius: BorderRadius.circular(12),
          ),
          child: Text(
            '已选 ${_picked.length} 本书 · 点击要发送到的电脑',
            style: TextStyle(
              fontSize: 13,
              color: JellyTheme.primary,
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
        Expanded(
          child: ListenableBuilder(
            listenable: PeerTransferService(),
            builder: (ctx, _) {
              final peers = PeerTransferService().onlinePeers;
              if (peers.isEmpty) {
                return Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const CircularProgressIndicator(strokeWidth: 2.5),
                      const SizedBox(height: 14),
                      const Text('正在搜索电脑…'),
                      const SizedBox(height: 4),
                      Text(
                        '请确认电脑端已开启「从手机接收」',
                        style: TextStyle(
                          fontSize: 12,
                          color: isDark
                              ? Colors.white38
                              : JellyTheme.textSecondary,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        '请确保手机与电脑在同一局域网',
                        style: TextStyle(
                          fontSize: 12,
                          color: isDark
                              ? Colors.white38
                              : JellyTheme.textSecondary,
                        ),
                      ),
                    ],
                  ),
                );
              }
              return ListView.separated(
                padding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 8,
                ),
                itemCount: peers.length,
                separatorBuilder: (_, _) => const SizedBox(height: 8),
                itemBuilder: (ctx, i) {
                  final p = peers[i];
                  return Material(
                    color: isDark ? JellyTheme.cardDark : JellyTheme.cardLight,
                    borderRadius: BorderRadius.circular(14),
                    elevation: 1,
                    child: ListTile(
                      onTap: () => _onPeerTapped(p),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(14),
                      ),
                      leading: Container(
                        width: 40,
                        height: 40,
                        decoration: BoxDecoration(
                          color: JellyTheme.primary.withValues(alpha: 0.12),
                          borderRadius: BorderRadius.circular(10),
                        ),
                        child: const Icon(
                          Icons.computer_rounded,
                          color: JellyTheme.primary,
                        ),
                      ),
                      title: Text(p.name),
                      subtitle: Text(
                        p.platform,
                        style: const TextStyle(fontSize: 12),
                      ),
                      trailing: const Icon(
                        Icons.send_rounded,
                        color: JellyTheme.primary,
                      ),
                    ),
                  );
                },
              );
            },
          ),
        ),
      ],
    );
  }

  Widget _buildSending() {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    if (_sendDone) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                _sendOk
                    ? Icons.check_circle_rounded
                    : Icons.error_outline_rounded,
                size: 64,
                color: _sendOk
                    ? Colors.green
                    : (isDark ? Colors.redAccent : Colors.red),
              ),
              const SizedBox(height: 16),
              Text(
                _sendOk ? '发送成功' : '发送失败',
                style: const TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 24),
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  OutlinedButton(
                    onPressed: () => setState(() {
                      _stage = _SendStage.source;
                      _picked.clear();
                      _sendDone = false;
                    }),
                    child: const Text('再发一本'),
                  ),
                  const SizedBox(width: 12),
                  FilledButton(
                    onPressed: () => Navigator.pop(context),
                    child: const Text('返回'),
                  ),
                ],
              ),
            ],
          ),
        ),
      );
    }
    final pct = (_total > 0) ? (_sent / _total).clamp(0.0, 1.0) : 0.0;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const CircularProgressIndicator(strokeWidth: 2.5),
            const SizedBox(height: 20),
            Text(
              _fileCount > 1
                  ? '正在发送第 ${_fileIdx + 1}/$_fileCount 个文件'
                  : '正在发送…',
              style: const TextStyle(fontSize: 15),
            ),
            const SizedBox(height: 12),
            LinearProgressIndicator(value: pct),
            const SizedBox(height: 8),
            Text(
              _total > 0 ? '${_fmtSize(_sent)} / ${_fmtSize(_total)}' : '',
              style: TextStyle(
                fontSize: 12,
                color: isDark ? Colors.white54 : JellyTheme.textSecondary,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildReceive() {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Column(
      children: [
        ListenableBuilder(
          listenable: PeerTransferService(),
          builder: (ctx, _) {
            final receiving = PeerTransferService().isReceiving;
            return Container(
              width: double.infinity,
              margin: const EdgeInsets.all(16),
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: isDark ? JellyTheme.cardDark : JellyTheme.cardLight,
                borderRadius: BorderRadius.circular(16),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withValues(alpha: isDark ? 0.4 : 0.06),
                    blurRadius: 12,
                    offset: const Offset(0, 4),
                  ),
                ],
              ),
              child: Column(
                children: [
                  Icon(
                    receiving
                        ? Icons.wifi_tethering_rounded
                        : Icons.wifi_tethering_off_rounded,
                    size: 40,
                    color: receiving
                        ? JellyTheme.primary
                        : (isDark ? Colors.white38 : JellyTheme.textSecondary),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    receiving ? '等待电脑传书' : '接收未开启',
                    style: const TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    receiving ? '保持开启即可接收，息屏也可收' : '点击下方按钮开启接收',
                    style: TextStyle(
                      fontSize: 12,
                      color: isDark ? Colors.white54 : JellyTheme.textSecondary,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    '请确保手机与电脑在同一局域网',
                    style: TextStyle(
                      fontSize: 12,
                      color: isDark ? Colors.white38 : JellyTheme.textSecondary,
                    ),
                  ),
                  const SizedBox(height: 12),
                  SizedBox(
                    width: double.infinity,
                    child: FilledButton.icon(
                      onPressed: _receiveStarting ? null : _toggleReceive,
                      icon: _receiveStarting
                          ? const SizedBox(
                              width: 16,
                              height: 16,
                              child: CircularProgressIndicator(
                                strokeWidth: 2,
                                color: Colors.white,
                              ),
                            )
                          : Icon(
                              receiving
                                  ? Icons.stop_rounded
                                  : Icons.play_arrow_rounded,
                            ),
                      label: Text(receiving ? '停止接收' : '开启接收'),
                      style: FilledButton.styleFrom(
                        backgroundColor: receiving
                            ? Colors.red
                            : JellyTheme.primary,
                      ),
                    ),
                  ),
                ],
              ),
            );
          },
        ),
        Expanded(
          child: _events.isEmpty
              ? const SizedBox.shrink()
              : ListView.builder(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  itemCount: _events.length,
                  itemBuilder: (ctx, i) {
                    return ListTile(
                      leading: const Icon(
                        Icons.history_rounded,
                        size: 20,
                        color: Colors.grey,
                      ),
                      title: Text(
                        _events[i],
                        style: const TextStyle(fontSize: 13),
                      ),
                    );
                  },
                ),
        ),
      ],
    );
  }

  // ===================== helpers =====================

  Widget _dragHandle(bool isDark) => Container(
    width: 36,
    height: 4,
    decoration: BoxDecoration(
      color: isDark
          ? Colors.white.withValues(alpha: 0.2)
          : Colors.black.withValues(alpha: 0.15),
      borderRadius: BorderRadius.circular(2),
    ),
  );

  String _extLabel(String filename) {
    final dot = filename.lastIndexOf('.');
    return dot <= 0 ? '' : filename.substring(dot + 1).toUpperCase();
  }

  String _fmtSize(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    if (bytes < 1024 * 1024 * 1024) {
      return '${(bytes / 1024 / 1024).toStringAsFixed(1)} MB';
    }
    return '${(bytes / 1024 / 1024 / 1024).toStringAsFixed(2)} GB';
  }
}

/// 书架选书弹层：列出已下载/本地导入的书，多选后返回 [_PickedFile] 列表。
class _ShelfPickSheet extends StatefulWidget {
  const _ShelfPickSheet();

  @override
  State<_ShelfPickSheet> createState() => _ShelfPickSheetState();
}

class _ShelfPickSheetState extends State<_ShelfPickSheet> {
  final Set<String> _selected = {};
  String _query = '';

  List<BookDownloadTask> get _allTasks =>
      BookDownloadService().tasks.values
          .where(
            (t) =>
                t.localPath != null && t.status == BookDownloadStatus.completed,
          )
          .toList()
        ..sort((a, b) => (b.downloadedAt ?? 0).compareTo(a.downloadedAt ?? 0));

  List<BookDownloadTask> get _filteredTasks {
    final q = _query.trim().toLowerCase();
    if (q.isEmpty) return _allTasks;
    return _allTasks
        .where(
          (t) =>
              t.title.toLowerCase().contains(q) ||
              (t.author ?? '').toLowerCase().contains(q),
        )
        .toList();
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final all = _allTasks;
    final tasks = _filteredTasks;
    final height = MediaQuery.of(context).size.height * 0.7;
    return Container(
      height: height,
      decoration: BoxDecoration(
        color: isDark ? const Color(0xFF1E1E3A) : Colors.white,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
      ),
      child: SafeArea(
        top: false,
        child: Column(
          children: [
            const SizedBox(height: 12),
            Container(
              width: 36,
              height: 4,
              decoration: BoxDecoration(
                color: isDark
                    ? Colors.white.withValues(alpha: 0.2)
                    : Colors.black.withValues(alpha: 0.15),
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            const SizedBox(height: 10),
            const Text(
              '选择要发送的书',
              style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 4),
            Text(
              '共 ${all.length} 本可发送',
              style: TextStyle(
                fontSize: 12,
                color: isDark ? Colors.white54 : JellyTheme.textSecondary,
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
              child: TextField(
                onChanged: (v) => setState(() => _query = v),
                decoration: InputDecoration(
                  hintText: '搜索书名 / 作者',
                  prefixIcon: const Icon(Icons.search, size: 20),
                  isDense: true,
                  contentPadding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 10,
                  ),
                  suffixIcon: _query.isEmpty
                      ? null
                      : IconButton(
                          icon: const Icon(Icons.close, size: 18),
                          onPressed: () => setState(() => _query = ''),
                        ),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                    borderSide: BorderSide.none,
                  ),
                  filled: true,
                  fillColor: isDark
                      ? Colors.white.withValues(alpha: 0.08)
                      : Colors.black.withValues(alpha: 0.05),
                ),
              ),
            ),
            const Divider(height: 16),
            if (all.isEmpty)
              Padding(
                padding: const EdgeInsets.all(32),
                child: Text(
                  '暂无可发送的书\n请先下载或导入图书',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    color: isDark ? Colors.white54 : JellyTheme.textSecondary,
                  ),
                ),
              )
            else if (tasks.isEmpty)
              Padding(
                padding: const EdgeInsets.all(32),
                child: Text(
                  '无匹配结果',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    color: isDark ? Colors.white54 : JellyTheme.textSecondary,
                  ),
                ),
              )
            else
              Expanded(
                child: ListView.builder(
                  itemCount: tasks.length,
                  itemBuilder: (ctx, i) {
                    final t = tasks[i];
                    final selected = _selected.contains(t.bookId);
                    return CheckboxListTile(
                      value: selected,
                      onChanged: (v) => setState(
                        () => v!
                            ? _selected.add(t.bookId)
                            : _selected.remove(t.bookId),
                      ),
                      title: Text(
                        t.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      subtitle: Text(
                        [
                          if (t.author != null) t.author,
                          (t.extension ?? '').toUpperCase(),
                          if (t.isLocalImport) '本地导入',
                        ].join(' · '),
                        style: const TextStyle(fontSize: 12),
                      ),
                    );
                  },
                ),
              ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  TextButton(
                    onPressed: () => Navigator.pop(context, null),
                    child: const Text('取消'),
                  ),
                  FilledButton(
                    onPressed: _selected.isEmpty
                        ? null
                        : () {
                            final picked = all
                                .where((t) => _selected.contains(t.bookId))
                                .map((t) {
                                  final sub =
                                      [
                                            if (t.author != null) t.author,
                                            (t.extension ?? '').toUpperCase(),
                                          ]
                                          .whereType<String>()
                                          .where((s) => s.isNotEmpty)
                                          .join(' · ');
                                  return _PickedFile(
                                    path: t.localPath!,
                                    title: t.title,
                                    subtitle: sub.isEmpty ? null : sub,
                                  );
                                })
                                .toList();
                            Navigator.pop(context, picked);
                          },
                    child: Text('加入清单(${_selected.length})'),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
