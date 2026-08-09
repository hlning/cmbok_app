import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:bonsoir/bonsoir.dart';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/book.dart';
import '../models/bookshelf.dart';
import '../models/peer_device.dart';
import '../models/transfer_offer.dart';
import 'book_download_service.dart';
import 'bookshelf_service.dart';
import 'settings_service.dart';

/// 跨设备传书后台服务（手机端）。
///
/// 对称 P2P：本机既可作接收方（起 HttpServer + mDNS 广播 + 前台保活），
/// 也可作发送方（mDNS 发现对端 + Dio 推送）。协议与电脑端一致：
/// `POST /transfer/offer` -> 轮询 `GET /transfer/offer/{id}` -> `POST /transfer`
/// -> `POST /transfer/offer/{id}/done`。
///
/// 鉴权 token-per-peer：每对设备配对时生成一个共享 token，双方各存一份。
/// 配对折叠进接收方「首次接受」：未配对对端发邀约时携带 X-Pair-Request，
/// 接收方接受后生成 token 随 accept 响应回传，发送方持久化。
class PeerTransferService extends ChangeNotifier {
  PeerTransferService._();
  static final PeerTransferService _instance = PeerTransferService._();
  factory PeerTransferService() => _instance;

  static const _kServiceType = '_cmbok._tcp';
  static const _kPeers = 'peer_transfer_peers';
  static const _kPeerId = 'peer_transfer_id';
  static const _kPeerName = 'peer_transfer_name';
  static const int _kDefaultPort = 25601;
  static const int _kForegroundServiceId = 25601;
  static const Duration _offerTimeout = Duration(minutes: 2);

  /// 接收后自动入本地书架的扩展名集合；其余落接收目录。
  static const _bookExts = {'epub', 'txt', 'pdf', 'mobi', 'azw', 'azw3'};

  String _peerId = '';
  String _peerName = '';
  String get peerId => _peerId;
  String get peerName => _peerName;

  /// 已配对（持久化）+ 已发现（运行时补 host/port/online）的对端。
  final Map<String, PeerDevice> _peers = {};
  List<PeerDevice> get peers => _peers.values.toList();
  List<PeerDevice> get onlinePeers =>
      _peers.values.where((p) => p.online).toList();

  /// 配对进行中（待定，未持久化）的对端，已有 token。
  final Map<String, PeerDevice> _pendingPeers = {};

  /// 接收到的邀约状态，按 offerId 索引。
  final Map<String, _OfferState> _offers = {};

  HttpServer? _server;
  int _port = _kDefaultPort;
  BonsoirBroadcast? _broadcast;
  BonsoirDiscovery? _discovery;
  // ignore: unused_field
  Timer? _cleanupTimer;
  bool _foregroundRunning = false;

  /// 前端设置：收到对端传书邀约时回调（主 isolate，可直接弹窗）。
  void Function(TransferOffer offer)? onIncomingOffer;

  /// 前端设置：接收模式事件回调（如空闲超时自动断开），主 isolate。
  void Function(String message)? onReceiveEvent;

  /// 接收空闲计时器：开启接收后长时间无邀约则自动断开（省电）。
  Timer? _idleTimer;
  static const Duration _idleTimeout = Duration(minutes: 10);

  bool get isReceiving => _server != null;
  bool get isDiscovering => _discovery != null;
  int get port => _port;

  void _log(Object? msg) {
    if (kDebugMode) print('[PeerTransfer] $msg');
  }

  // ===================== 初始化 =====================

  Future<void> init() async {
    final prefs = await SharedPreferences.getInstance();
    _peerId = prefs.getString(_kPeerId) ?? '';
    if (_peerId.isEmpty) {
      _peerId = _randomToken();
      await prefs.setString(_kPeerId, _peerId);
    }
    _peerName = prefs.getString(_kPeerName) ?? '';
    if (_peerName.isEmpty) {
      final tag = _peerId.substring(0, 4);
      final label = Platform.isAndroid
          ? '手机'
          : Platform.isWindows
          ? '电脑'
          : '设备';
      _peerName = 'Cmbok$label-$tag';
      await prefs.setString(_kPeerName, _peerName);
    }
    await _loadPeers(prefs);

    if (Platform.isAndroid) {
      FlutterForegroundTask.init(
        androidNotificationOptions: AndroidNotificationOptions(
          channelId: 'peer_transfer',
          channelName: '传书接收',
          channelDescription: '接收电脑/手机传书时保持运行（息屏可收）',
          onlyAlertOnce: true,
        ),
        iosNotificationOptions: const IOSNotificationOptions(
          showNotification: false,
          playSound: false,
        ),
        foregroundTaskOptions: ForegroundTaskOptions(
          eventAction: ForegroundTaskEventAction.nothing(),
          autoRunOnBoot: false,
          autoRunOnMyPackageReplaced: false,
          allowWakeLock: true,
          allowWifiLock: true,
        ),
      );
    }

    _cleanupTimer = Timer.periodic(
      const Duration(seconds: 30),
      (_) => _cleanupOffers(),
    );
    _log('初始化完成: $_peerName ($_peerId)，${_peers.length} 个已配对设备');
  }

  // ===================== 对端表持久化 =====================

  Future<void> _loadPeers(SharedPreferences prefs) async {
    final raw = prefs.getString(_kPeers);
    if (raw == null) return;
    try {
      final list = jsonDecode(raw) as List;
      for (final item in list) {
        final p = PeerDevice.fromJson(item as Map<String, dynamic>);
        _peers[p.id] = p;
      }
    } catch (e) {
      _log('加载对端失败: $e');
    }
  }

  Future<void> _savePeers() async {
    final prefs = await SharedPreferences.getInstance();
    final list = _peers.values.map((p) => p.toJson()).toList();
    await prefs.setString(_kPeers, jsonEncode(list));
  }

  // ===================== mDNS：广播（接收方） =====================

  Future<void> _startBroadcast() async {
    if (_broadcast != null) return;
    final svc = BonsoirService(
      name: _peerId,
      type: _kServiceType,
      port: _port,
      attributes: {
        'lib': 'bonsoir',
        'id': _peerId,
        'dev': _peerName,
        'plat': _platform(),
        'ver': '1',
      },
    );
    final b = BonsoirBroadcast(service: svc);
    await b.initialize();
    b.eventStream?.listen((e) {
      if (e is BonsoirBroadcastStartedEvent) {
        _log('已广播 $_peerName @ :$_port');
      }
    }, onError: (e) => _log('广播错误: $e'));
    await b.start();
    _broadcast = b;
  }

  Future<void> _stopBroadcast() async {
    await _broadcast?.stop();
    _broadcast = null;
  }

  // ===================== mDNS：发现（发送方） =====================

  Future<void> startDiscovery() async {
    if (_discovery != null) return;
    final d = BonsoirDiscovery(type: _kServiceType);
    await d.initialize();
    d.eventStream?.listen(_onDiscoveryEvent, onError: (e) => _log('发现错误: $e'));
    await d.start();
    _discovery = d;
    notifyListeners();
  }

  Future<void> stopDiscovery() async {
    await _discovery?.stop();
    _discovery = null;
    for (final p in _peers.values) {
      p.online = false;
    }
    notifyListeners();
  }

  void _onDiscoveryEvent(BonsoirDiscoveryEvent event) {
    final svc = event.service;
    if (svc == null) return;
    if (event is BonsoirDiscoveryServiceFoundEvent) {
      _discovery?.serviceResolver.resolveService(svc);
    } else if (event is BonsoirDiscoveryServiceResolvedEvent) {
      final id = svc.attributes['id'] ?? svc.name;
      final name = svc.attributes['dev'] ?? id;
      final platform = svc.attributes['plat'] ?? 'unknown';
      final peer = _peers.putIfAbsent(
        id,
        () => PeerDevice(id: id, name: name, platform: platform),
      );
      peer.name = name;
      peer.host = svc.host;
      peer.port = svc.port;
      peer.online = true;
      peer.lastSeen = DateTime.now();
      notifyListeners();
    } else if (event is BonsoirDiscoveryServiceLostEvent) {
      final id = svc.attributes['id'] ?? svc.name;
      final peer = _peers[id];
      if (peer != null) {
        peer.online = false;
        notifyListeners();
      }
    }
  }

  // ===================== 接收服务（HttpServer） =====================

  Future<bool> _startServer() async {
    if (_server != null) return true;
    HttpServer? server;
    for (var p = _kDefaultPort; p < _kDefaultPort + 6; p++) {
      try {
        server = await HttpServer.bind(InternetAddress.anyIPv4, p);
        _port = p;
        break;
      } catch (_) {
        // 端口占用，尝试下一个
      }
    }
    if (server == null) {
      try {
        server = await HttpServer.bind(InternetAddress.anyIPv4, 0);
        _port = server.port;
      } catch (e) {
        _log('绑定服务失败: $e');
        return false;
      }
    }
    _server = server;
    _log('接收服务已启动 @ 0.0.0.0:$_port');
    server.listen(_handleRequest, onError: (e) => _log('服务错误: $e'));
    return true;
  }

  Future<void> _stopServer() async {
    await _server?.close(force: true);
    _server = null;
  }

  Future<void> _handleRequest(HttpRequest request) async {
    try {
      final path = request.uri.path;
      final method = request.method;
      if (method == 'GET' && path == '/info') {
        return _json(request, _infoBody());
      }
      if (method == 'POST' && path == '/transfer/offer') {
        return await _handleOffer(request);
      }
      if (method == 'GET' && path.startsWith('/transfer/offer/')) {
        final id = path.substring('/transfer/offer/'.length);
        return _handlePoll(request, id);
      }
      if (method == 'POST' && path == '/transfer') {
        return await _handleTransfer(request);
      }
      if (method == 'POST' &&
          path.startsWith('/transfer/offer/') &&
          path.endsWith('/done')) {
        final id = path.substring(
          '/transfer/offer/'.length,
          path.length - '/done'.length,
        );
        return _handleDone(request, id);
      }
      request.response.statusCode = 404;
      await request.response.close();
    } catch (e, st) {
      _log('处理请求异常: $e\n$st');
      await _drainBody(request);
      await _jsonErr(request, 500, '内部错误: $e');
    }
  }

  Map<String, dynamic> _infoBody() => {
    'id': _peerId,
    'name': _peerName,
    'platform': _platform(),
    'ver': '1',
  };

  /// POST /transfer/offer：登记邀约并通知前端弹窗。
  Future<void> _handleOffer(HttpRequest request) async {
    final body = await _readJson(request);
    final callerId = request.headers.value('X-Peer-Id') ?? '';
    final auth = request.headers.value('Authorization');
    final pairReq = request.headers.value('X-Pair-Request') == '1';
    if (callerId.isEmpty) return _jsonErr(request, 400, '缺少 X-Peer-Id');

    final peerName = body?['peerName'] as String? ?? callerId;
    final peerPlatform = body?['peerPlatform'] as String? ?? 'unknown';
    final files =
        (body?['files'] as List?)
            ?.map((e) => TransferFile.fromJson(e as Map<String, dynamic>))
            .toList() ??
        [];
    final kind = body?['kind'] as String? ?? 'file';

    final PeerDevice? peer = _peers[callerId] ?? _pendingPeers[callerId];
    bool pairing = false;
    String? pairToken;
    if (peer != null && peer.token != null && auth == 'Bearer ${peer.token}') {
      // 已配对，正常邀约
    } else if (pairReq) {
      // 配对：生成 token，建立待定对端
      pairing = true;
      pairToken = _randomToken();
      _pendingPeers[callerId] = PeerDevice(
        id: callerId,
        name: peerName,
        platform: peerPlatform,
        token: pairToken,
      );
    } else {
      return _jsonErr(request, 401, '未授权，需重新配对');
    }

    // 记录对端可达地址（来自连接），便于后续主动回连
    final target = peer ?? _pendingPeers[callerId]!;
    target.host = request.connectionInfo?.remoteAddress.address;
    target.online = true;
    target.lastSeen = DateTime.now();

    final offerId = _randomToken().substring(0, 12);
    final offer = TransferOffer(
      id: offerId,
      peerId: callerId,
      peerName: peerName,
      peerPlatform: peerPlatform,
      files: files,
      kind: kind,
      createdAt: DateTime.now(),
    );
    _offers[offerId] = _OfferState(
      offer: offer,
      peerId: callerId,
      token: pairing ? pairToken : peer?.token,
      pairing: pairing,
    );

    // 有设备连接进来，重置接收空闲计时器
    _resetIdleTimer();

    // 通知前端弹「是否接收」窗
    final cb = onIncomingOffer;
    if (cb != null) cb(offer);

    final resp = <String, dynamic>{'offerId': offerId, 'status': 'pending'};
    if (pairing && pairToken != null) resp['pairToken'] = pairToken;
    return _json(request, resp, status: 202);
  }

  /// GET /transfer/offer/{id}：发送方轮询结果。
  Future<void> _handlePoll(HttpRequest request, String offerId) async {
    final st = _offers[offerId];
    if (st == null) return _jsonErr(request, 404, '邀约不存在或已过期');
    if (!_checkOfferAuth(request, st)) return _jsonErr(request, 401, '未授权');
    final m = <String, dynamic>{'status': st.offer.status.name};
    if (st.offer.status == TransferStatus.accepted && st.offer.dir != null) {
      m['dir'] = st.offer.dir;
    }
    return _json(request, m);
  }

  /// POST /transfer?offerId=：接收一个文件（流式），书自动入本地书架。
  Future<void> _handleTransfer(HttpRequest request) async {
    final offerId = request.uri.queryParameters['offerId'];
    final st = offerId == null ? null : _offers[offerId];
    if (st == null) return _reject(request, 404, '邀约不存在');
    if (!_checkOfferAuth(request, st)) return _reject(request, 401, '未授权');
    if (st.offer.status != TransferStatus.accepted) {
      return _reject(request, 409, '对端尚未接受');
    }

    final filename = Uri.decodeComponent(
      request.headers.value('X-Filename') ?? 'file.bin',
    );
    final kind = request.headers.value('X-Kind') ?? 'file';
    final dir = st.offer.dir ?? (await _defaultReceiveDir()).path;
    await Directory(dir).create(recursive: true);
    final safe = _sanitizeFilename(filename);
    final destPath = '$dir/$safe';

    final sink = File(destPath).openWrite();
    try {
      await for (final chunk in request) {
        sink.add(chunk);
        st.lastActivity = DateTime.now(); // 传输活跃，避免被清理误杀
      }
      await sink.flush();
    } catch (e) {
      await sink.close();
      try {
        await File(destPath).delete();
      } catch (_) {}
      await _drainBody(request);
      return _jsonErr(request, 500, '写入失败: $e');
    }
    await sink.close();
    st.lastActivity = DateTime.now();

    final ext = _extOf(safe);
    if (kind == 'book' && _bookExts.contains(ext)) {
      String? bookId;
      try {
        bookId = await BookDownloadService().importLocalFile(
          File(destPath),
          title: _titleOf(safe),
          extension: ext,
        );
      } catch (e) {
        _log('入库失败，保留原文件: $e');
        return _json(request, {
          'ok': true,
          'savedPath': destPath,
          'note': '入库失败已保留文件',
        });
      }
      if (bookId == null) {
        // importLocalFile 内部失败，保留原文件不删除
        _log('入库返回空，保留原文件: $destPath');
        return _json(request, {
          'ok': true,
          'savedPath': destPath,
          'note': '入库失败已保留文件',
        });
      }
      // 入库成功：加入「本地图书」书架（对齐手动导入流程）
      try {
        final shelf = await BookshelfService().ensureLocalBookshelf();
        final cover = BookDownloadService().task(bookId)?.cover;
        final meta = jsonEncode(
          Book(
            id: bookId,
            hash: '',
            title: _titleOf(safe),
            cover: cover,
            extension: ext,
          ).toJson(),
        );
        await BookshelfService().addToBookshelf(
          shelf.id,
          bookId,
          BookshelfItemType.book,
          meta: meta,
        );
      } catch (e) {
        _log('加入书架失败（不影响入库）: $e');
      }
      // importLocalFile 已复制进 Books/，删除接收目录暂存
      try {
        await File(destPath).delete();
      } catch (_) {}
      return _json(request, {'ok': true, 'bookId': bookId});
    }
    return _json(request, {'ok': true, 'savedPath': destPath});
  }

  /// POST /transfer/offer/{id}/done：发送完毕。
  Future<void> _handleDone(HttpRequest request, String offerId) async {
    final st = _offers[offerId];
    if (st != null) {
      if (!_checkOfferAuth(request, st)) return _jsonErr(request, 401, '未授权');
      st.offer.status = TransferStatus.done;
      _offers.remove(offerId);
      // 通知前端：发送方已传完所有文件（区别于“已接受”时的“正在接收”）
      onReceiveEvent?.call(
        '接收完成：${st.offer.peerName} 的 ${st.offer.fileCount} 个文件',
      );
    }
    return _json(request, {'ok': true});
  }

  bool _checkOfferAuth(HttpRequest request, _OfferState st) {
    final callerId = request.headers.value('X-Peer-Id') ?? '';
    if (callerId != st.peerId) return false;
    if (st.token == null) return false;
    final auth = request.headers.value('Authorization');
    return auth == 'Bearer ${st.token}';
  }

  /// 提前拒绝时先排空请求体：发送方总是流式上传整个文件，若不排空就 close，
  /// 发送方会收到连接中止(10053)且读不到错误响应。
  Future<void> _reject(HttpRequest request, int status, String msg) async {
    await _drainBody(request);
    await _jsonErr(request, status, msg);
  }

  Future<void> _drainBody(HttpRequest request) async {
    try {
      await request.drain<void>();
    } catch (_) {
      // 排空失败忽略，不掩盖原始错误
    }
  }

  // ===================== 接收方：响应邀约（前端调用） =====================

  /// 前端在「是否接收」弹窗中调用。accept=true 且 dir 为空则用默认接收目录。
  Future<void> respondToOffer(
    String offerId, {
    required bool accept,
    String? dir,
  }) async {
    final st = _offers[offerId];
    if (st == null) return;
    if (accept) {
      st.offer.status = TransferStatus.accepted;
      st.offer.dir = dir ?? (await _defaultReceiveDir()).path;
      st.lastActivity = DateTime.now();
      // 配对落定：待定对端转正式并持久化
      final pending = _pendingPeers.remove(st.peerId);
      if (pending != null) {
        _peers[pending.id] = pending;
        await _savePeers();
      }
    } else {
      st.offer.status = TransferStatus.rejected;
      _pendingPeers.remove(st.peerId);
    }
    notifyListeners();
  }

  // ===================== 接收模式 / 发送模式 =====================

  /// 接收模式：起服务 + 广播 + 前台保活（息屏可收）。
  Future<bool> enterReceiveMode() async {
    final ok = await _startServer();
    if (!ok) return false;
    await _startBroadcast();
    await _startForeground();
    _resetIdleTimer();
    notifyListeners();
    return true;
  }

  Future<void> exitReceiveMode() async {
    _idleTimer?.cancel();
    _idleTimer = null;
    await _stopForeground();
    await _stopBroadcast();
    await _stopServer();
    _offers.clear();
    notifyListeners();
  }

  /// 重置接收空闲计时器：开启接收或收到邀约时调用。
  void _resetIdleTimer() {
    _idleTimer?.cancel();
    _idleTimer = Timer(_idleTimeout, _onIdleTimeout);
  }

  /// 接收空闲超时：长时间无设备连接进来，自动退出接收模式。
  Future<void> _onIdleTimeout() async {
    if (!isReceiving) return;
    _log('接收空闲超时，自动停止接收');
    await exitReceiveMode();
    onReceiveEvent?.call('长时间无连接，已自动停止接收');
  }

  /// 发送模式：发现对端（前端选中文件后调 [sendToPeer]）。
  /// 也可单独用于刷新对端列表。
  Future<void> enterSendMode() => startDiscovery();
  Future<void> exitSendMode() => stopDiscovery();

  /// 快速探活对端：TCP 连其 HTTP 端口（2s 超时）。失败则标记离线并通知。
  /// 发送前拦截 mDNS 缓存残留的已下线设备，避免点了才失败。
  Future<bool> checkPeerReachable(String peerId) async {
    final peer = _peers[peerId];
    if (peer == null || peer.host == null || peer.port == null) return false;
    try {
      final socket = await Socket.connect(
        peer.host!,
        peer.port!,
        timeout: const Duration(seconds: 2),
      );
      await socket.close();
      return true;
    } catch (e) {
      _log('对端探活失败 $peerId: $e');
      peer.online = false;
      notifyListeners();
      return false;
    }
  }

  /// 发送文件到对端。返回 offerId 成功，null 失败。
  /// onProgress(sent, total, fileIndex, fileCount) 报告每文件进度。
  Future<String?> sendToPeer(
    String peerId,
    List<String> filePaths, {
    void Function(int sent, int total, int fileIndex, int fileCount)?
    onProgress,
  }) async {
    final peer = _peers[peerId];
    if (peer == null || peer.address == null) {
      _log('对端不可达: $peerId');
      return null;
    }
    final base = 'http://${peer.address}';
    final dio = Dio(
      BaseOptions(
        connectTimeout: const Duration(seconds: 10),
        receiveTimeout: const Duration(minutes: 10),
      ),
    );
    try {
      // 构造文件清单
      final files = <TransferFile>[];
      for (final p in filePaths) {
        final f = File(p);
        if (!await f.exists()) {
          _log('文件不存在: $p');
          continue;
        }
        final name = p.split(RegExp(r'[/\\]')).last;
        final size = await f.length();
        final ext = _extOf(name);
        files.add(
          TransferFile(
            name: name,
            size: size,
            kind: _bookExts.contains(ext) ? 'book' : 'file',
            path: p,
            mime: _mimeOf(ext),
          ),
        );
      }
      if (files.isEmpty) return null;
      final kind = files.every((f) => f.kind == 'book') ? 'book' : 'file';

      // 1) 发邀约（未配对则带 X-Pair-Request；401 则清 token 重配一次）
      final offerRes = await _postOffer(dio, base, peer, files, kind);
      if (offerRes == null) return null;
      final offerId = offerRes['offerId'] as String;
      final pairToken = offerRes['pairToken'] as String?;
      if (pairToken != null && peer.token != pairToken) {
        peer.token = pairToken;
        await _savePeers();
      }

      // 2) 轮询等待接受
      final authHeaders = {
        'X-Peer-Id': _peerId,
        'Authorization': 'Bearer ${peer.token}',
      };
      TransferStatus status = TransferStatus.pending;
      final deadline = DateTime.now().add(_offerTimeout);
      while (DateTime.now().isBefore(deadline)) {
        await Future.delayed(const Duration(milliseconds: 1500));
        try {
          final pr = await dio.get(
            '$base/transfer/offer/$offerId',
            options: Options(headers: authHeaders),
          );
          final s = (pr.data as Map)['status'] as String;
          if (s == 'accepted') {
            status = TransferStatus.accepted;
            break;
          } else if (s == 'rejected' || s == 'expired') {
            status = TransferStatus.rejected;
            break;
          }
        } on DioException catch (e) {
          if (e.response?.statusCode == 404) {
            status = TransferStatus.rejected;
            break;
          }
          _log('轮询异常: ${e.message}');
        }
      }
      if (status != TransferStatus.accepted) {
        _log('对端未接受或超时');
        return null;
      }

      // 3) 逐个传文件（流式 + 进度）
      for (var i = 0; i < files.length; i++) {
        final tf = files[i];
        final flen = tf.size;
        await dio.post(
          '$base/transfer?offerId=$offerId',
          data: File(tf.path!).openRead(),
          options: Options(
            headers: {
              ...authHeaders,
              'Content-Type': 'application/octet-stream',
              'Content-Length': flen,
              'X-Filename': Uri.encodeComponent(tf.name),
              'X-Filesize': '$flen',
              'X-Mime': tf.mime ?? 'application/octet-stream',
              'X-Kind': tf.kind,
            },
            receiveTimeout: const Duration(minutes: 30),
          ),
          onSendProgress: (sent, total) =>
              onProgress?.call(sent, total, i, files.length),
        );
      }

      // 4) 完成
      await dio.post(
        '$base/transfer/offer/$offerId/done',
        options: Options(headers: authHeaders),
      );
      _log('传书完成: ${files.length} 个文件 -> ${peer.name}');
      return offerId;
    } on DioException catch (e) {
      _log('传书失败: ${e.message}');
      // 401：配对失效，清 token 以便下次重配
      if (e.response?.statusCode == 401 && peer.token != null) {
        peer.token = null;
        await _savePeers();
      }
      return null;
    } catch (e, st) {
      _log('传书异常: $e\n$st');
      return null;
    } finally {
      dio.close();
    }
  }

  /// 发送邀约；未配对带 X-Pair-Request，401 则清 token 重试一次。
  Future<Map<String, dynamic>?> _postOffer(
    Dio dio,
    String base,
    PeerDevice peer,
    List<TransferFile> files,
    String kind,
  ) async {
    for (var attempt = 0; attempt < 2; attempt++) {
      final pairing = peer.token == null;
      final headers = <String, dynamic>{
        'X-Peer-Id': _peerId,
        'Content-Type': 'application/json',
        if (!pairing) 'Authorization': 'Bearer ${peer.token}',
        if (pairing) 'X-Pair-Request': '1',
      };
      try {
        final res = await dio.post(
          '$base/transfer/offer',
          data: jsonEncode({
            'files': files.map((f) => f.toJson()).toList(),
            'kind': kind,
            'peerName': _peerName,
            'peerPlatform': _platform(),
          }),
          options: Options(headers: headers),
        );
        return Map<String, dynamic>.from(res.data as Map);
      } on DioException catch (e) {
        if (e.response?.statusCode == 401 &&
            peer.token != null &&
            attempt == 0) {
          _log('配对失效，重新配对');
          peer.token = null;
          continue;
        }
        _log('发邀约失败: ${e.message}');
        return null;
      }
    }
    return null;
  }

  // ===================== 前台服务（Android 息屏保活） =====================

  Future<void> _startForeground() async {
    if (!Platform.isAndroid || _foregroundRunning) return;
    final perm = await FlutterForegroundTask.checkNotificationPermission();
    if (perm != NotificationPermission.granted) {
      await FlutterForegroundTask.requestNotificationPermission();
    }
    if (!await FlutterForegroundTask.isIgnoringBatteryOptimizations) {
      await FlutterForegroundTask.requestIgnoreBatteryOptimization();
    }
    if (!await FlutterForegroundTask.isRunningService) {
      await FlutterForegroundTask.startService(
        serviceId: _kForegroundServiceId,
        notificationTitle: 'Cmbok 传书接收中',
        notificationText: '可在息屏时接收电脑/手机传书',
        callback: transferStartCallback,
      );
    }
    _foregroundRunning = await FlutterForegroundTask.isRunningService;
    if (!_foregroundRunning) {
      _log('前台服务启动失败');
    }
  }

  Future<void> _stopForeground() async {
    if (!Platform.isAndroid || !_foregroundRunning) return;
    await FlutterForegroundTask.stopService();
    _foregroundRunning = false;
  }

  // ===================== 工具 =====================

  String _platform() => Platform.isAndroid
      ? 'android'
      : Platform.isWindows
      ? 'windows'
      : Platform.isMacOS
      ? 'macos'
      : Platform.isIOS
      ? 'ios'
      : 'other';

  String _randomToken() {
    final r = Random.secure();
    final bytes = List<int>.generate(16, (_) => r.nextInt(256));
    return bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  }

  Future<Directory> _defaultReceiveDir() async {
    final base = await SettingsService.downloadBaseDir();
    final d = Directory('${base.path}/transfer');
    if (!await d.exists()) await d.create(recursive: true);
    return d;
  }

  String _sanitizeFilename(String name) {
    final clean = name.replaceAll(RegExp(r'[/\\]'), '_').trim();
    return clean.isEmpty ? 'file.bin' : clean;
  }

  String _extOf(String filename) {
    final dot = filename.lastIndexOf('.');
    return dot <= 0 ? '' : filename.substring(dot + 1).toLowerCase();
  }

  String _titleOf(String filename) {
    final dot = filename.lastIndexOf('.');
    return dot <= 0 ? filename : filename.substring(0, dot);
  }

  String _mimeOf(String ext) {
    switch (ext) {
      case 'epub':
        return 'application/epub+zip';
      case 'pdf':
        return 'application/pdf';
      case 'txt':
        return 'text/plain';
      case 'mobi':
        return 'application/x-mobipocket-ebook';
      default:
        return 'application/octet-stream';
    }
  }

  void _cleanupOffers() {
    final now = DateTime.now();
    final expired = <String>[];
    _offers.forEach((id, st) {
      if (now.difference(st.lastActivity) > const Duration(minutes: 5)) {
        expired.add(id);
        if (st.pairing) _pendingPeers.remove(st.peerId);
      }
    });
    if (expired.isNotEmpty) {
      for (final id in expired) {
        _offers.remove(id);
      }
      notifyListeners();
    }
  }

  Future<void> _json(
    HttpRequest request,
    Map<String, dynamic> body, {
    int status = 200,
  }) async {
    request.response.statusCode = status;
    request.response.headers.contentType = ContentType.json;
    request.response.write(jsonEncode(body));
    await request.response.close();
  }

  Future<void> _jsonErr(HttpRequest request, int status, String msg) =>
      _json(request, {'ok': false, 'message': msg}, status: status);

  Future<Map<String, dynamic>?> _readJson(HttpRequest request) async {
    try {
      final body = await utf8.decoder.bind(request).join();
      if (body.isEmpty) return null;
      return jsonDecode(body) as Map<String, dynamic>;
    } catch (_) {
      return null;
    }
  }
}

/// 邀约运行态。
class _OfferState {
  _OfferState({
    required this.offer,
    required this.peerId,
    required this.token,
    this.pairing = false,
  }) : lastActivity = offer.createdAt;
  final TransferOffer offer;
  final String peerId;

  /// 邀约创建时快照的鉴权 token。配对竞态下对端可能已重新配对拿到新 token，
  /// 而 _peers 里仍存旧 token，故鉴权以本邀约创建时的 token 为准，不查对端表。
  final String? token;
  final bool pairing;

  /// 最近活动时间（接受/每收到数据块时刷新）。清理按此判过期，避免误杀在传邀约。
  DateTime lastActivity;
}

/// 前台服务入口（必须在顶层，供独立 isolate 调用）。仅作保活，不跑业务逻辑。
@pragma('vm:entry-point')
void transferStartCallback() {
  FlutterForegroundTask.setTaskHandler(_KeepAliveTaskHandler());
}

class _KeepAliveTaskHandler extends TaskHandler {
  @override
  Future<void> onStart(DateTime timestamp, TaskStarter starter) async {}

  @override
  void onRepeatEvent(DateTime timestamp) {}

  @override
  Future<void> onDestroy(DateTime timestamp, bool isTimeout) async {}
}
