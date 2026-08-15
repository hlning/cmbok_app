import 'dart:async';
import 'dart:isolate';
import 'dart:typed_data';

import '../models/book_content.dart';
import 'book_parser.dart';

/// 在常驻后台 isolate 中解析 TXT。
///
/// `gbk_codec` 的 `gbk_bytes` 是一张 531KB 的映射表，首次访问时惰性构建，
/// 耗时可达秒级。若在主 isolate 解码（含表初始化）会阻塞 UI 触发 ANR；
/// 若每次走 [compute] 又会在新生 isolate 内反复重建该表。故此处起一个
/// 常驻 isolate：表只构建一次（在后台线程），后续 TXT 导入复用，主
/// isolate 全程不阻塞。主 isolate 读字节后以 [TransferableTypedData]
/// 零拷贝传入，worker 解码 + 分行后回传 [BookContent]。
class GbkTxtParser {
  GbkTxtParser._();
  static final GbkTxtParser instance = GbkTxtParser._();

  final ReceivePort _respPort = ReceivePort();
  SendPort? _cmdPort;
  Future<void>? _startup;
  final Map<int, Completer<BookContent>> _pending = {};
  int _nextId = 0;

  Future<void> _ensureStarted() => _startup ??= _start();

  Future<void> _start() async {
    final handshake = Completer<void>();
    _respPort.listen((msg) {
      if (msg is SendPort) {
        _cmdPort = msg;
        if (!handshake.isCompleted) handshake.complete();
        return;
      }
      if (msg is _Response) {
        final c = _pending.remove(msg.id);
        if (c == null) return;
        if (msg.error != null) {
          c.completeError(msg.error!);
        } else {
          c.complete(msg.result);
        }
      }
    });
    try {
      await Isolate.spawn(_txtWorkerEntry, _respPort.sendPort);
      await handshake.future;
    } catch (e) {
      _startup = null; // 允许下次重试
      rethrow;
    }
  }

  /// 解析 TXT 字节为 [BookContent]（后台 isolate 解码 + 分行，主线程不阻塞）。
  Future<BookContent> parse(Uint8List bytes, String title) async {
    try {
      await _ensureStarted();
    } catch (_) {
      // worker 起不来时退回一次性 isolate：仍在后台，仅多一次建表开销
      return _fallback(bytes, title);
    }
    final id = _nextId++;
    final c = Completer<BookContent>();
    _pending[id] = c;
    try {
      _cmdPort!.send((id, TransferableTypedData.fromList([bytes]), title));
    } catch (e) {
      _pending.remove(id);
      return _fallback(bytes, title);
    }
    try {
      return await c.future;
    } catch (_) {
      return _fallback(bytes, title);
    }
  }

  /// 一次性后台 isolate 兜底：解码 + 分行都在子 isolate，不阻塞主线程。
  Future<BookContent> _fallback(Uint8List bytes, String title) {
    return Isolate.run(() {
      final text = BookParser.decodeTxtBytes(bytes);
      return BookParser.buildTxtContent((text, title));
    });
  }
}

/// worker → 主 isolate 的响应包（纯数据，可跨 isolate 拷贝）。
class _Response {
  final int id;
  final BookContent? result;
  final Object? error;
  const _Response(this.id, this.result, this.error);
}

/// TXT 解析 worker isolate 入口。
void _txtWorkerEntry(SendPort respPort) {
  final cmdPort = ReceivePort();
  respPort.send(cmdPort.sendPort);
  cmdPort.listen((msg) {
    final (int id, TransferableTypedData td, String title) =
        msg as (int, TransferableTypedData, String);
    try {
      final bytes = td.materialize().asUint8List();
      final text = BookParser.decodeTxtBytes(bytes);
      final content = BookParser.buildTxtContent((text, title));
      respPort.send(_Response(id, content, null));
    } catch (e) {
      respPort.send(_Response(id, null, e));
    }
  });
}
