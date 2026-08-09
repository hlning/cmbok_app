import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

import '../models/book_content.dart';
import 'book_paginator.dart';

/// 预计算分页结果的磁盘缓存：把排版后的 [pages] + 图片宽高比持久化，
/// 避免同设备同参数每次打开都重新 TextPainter 度量。
///
/// [PageEntry.block] 是对象引用无法直接序列化，改存它在 flatBlocks 中的索引，
/// 反序列化时用当前 [BookContent.flatBlocks] 重建引用——故 read 需要传入 content。
/// 重建（[_restorePages]）在主线程用 content.flatBlocks 原实例完成，保证 block
/// identity 与主线程一致：read 命中后再 write（如改字号重排、续分页完成回写）
/// 时 identity map idx 才命中（[BookBlock] 未重写 == / hashCode）。
///
/// 支持 partial：未分页完的进度（已 commit 页 + 分页器半满页状态）也可持久化，
/// 下次 read 命中后用 [BookPaginator.resume] 断点续分页，避免大书从头重排。
class BookPageCacheService {
  BookPageCacheService._();
  static final BookPageCacheService _instance = BookPageCacheService._();
  static BookPageCacheService get instance => _instance;

  /// 每个 bookId 最多保留的缓存条目数（不同排版参数 / 视口），超出按最旧淘汰。
  static const _maxEntriesPerBook = 8;

  /// 触发 isolate 解码的缓存大小阈值。
  static const _isolateThreshold = 1 << 20; // 1MB

  /// 内容指纹：块数 + 全文字符数。区分同 bookId 但文件内容变化的不同版本。
  /// 仅 O(n) 取 length，远快于 TextPainter 度量。
  static String contentFingerprint(BookContent content) {
    final blocks = content.flatBlocks;
    var chars = 0;
    for (final b in blocks) {
      if (b is ParagraphBlock) {
        chars += b.text.length;
      } else if (b is HeadingBlock) {
        chars += b.text.length;
      }
    }
    return '${blocks.length}x$chars';
  }

  /// 完整缓存键：视口 + 排版参数 + bookId + 内容指纹。
  /// 阅读器 _buildPaged 与过渡页共用同一格式，确保两者判等一致。
  static String keyOf({
    required double vpW,
    required double vpH,
    required BookTypography typo,
    required String bookId,
    required String fingerprint,
  }) {
    return '${vpW.toInt()}x${vpH.toInt()}'
        ':${typo.fontSize}:${typo.lineHeight}:${typo.padding}:${typo.verticalPadding}:${typo.fontFamily}:${typo.textScaler.scale(1.0)}'
        ':${typo.inheritedStyle.hashCode}'
        ':$bookId:$fingerprint';
  }

  Future<File> _file(String bookId) async {
    final dir = await getApplicationSupportDirectory();
    final cacheDir = Directory('${dir.path}/book_pagination_cache');
    if (!await cacheDir.exists()) await cacheDir.create(recursive: true);
    return File('${cacheDir.path}/$bookId.json');
  }

  /// 读缓存。返回 null 表示无此 key 或解析失败（调用方回退重排）。
  /// 大书（>1MB）在 isolate 做 jsonDecode + 取命中条目（raw Map）；重建 pages
  /// 回主线程用 content.flatBlocks 原实例，保证 block identity 与主线程一致
  /// （read 后再 write 的 idx 才命中，详见类注释）。
  /// partial 命中时返回续分页所需的半满页状态。
  Future<
    ({
      List<BookPage> pages,
      Map<String, double> ratios,
      bool partial,
      int? resumeBlockIndex,
      List<PageEntry>? cur,
      int? curFirst,
      double? remaining,
    })?
  >
  read({
    required String bookId,
    required String key,
    required BookContent content,
  }) async {
    try {
      final f = await _file(bookId);
      if (!await f.exists()) return null;
      final raw = await f.readAsString();
      final args = _PageDecodeArgs(raw, key);
      final rawEntry = raw.length > _isolateThreshold
          ? await compute(_decodeRawEntry, args)
          : _decodeRawEntry(args);
      if (rawEntry == null) return null;
      return _restorePages(rawEntry, content.flatBlocks);
    } catch (_) {
      return null;
    }
  }

  /// 写缓存。[flatBlocks] 必须是 pages / cur 内 block 引用所属的同一个实例，
  /// identity 反查索引才命中。[partial]=true 时一并写入半满页状态，供断点续分页。
  /// 同 key 重写会提升到末尾（LRU），超出上限淘汰最旧。
  Future<void> write({
    required String bookId,
    required String key,
    required List<BookPage> pages,
    required Map<String, double> ratios,
    required List<BookBlock> flatBlocks,
    bool partial = false,
    int? resumeBlockIndex,
    List<PageEntry>? cur,
    int? curFirst,
    double? remaining,
  }) async {
    try {
      final f = await _file(bookId);
      Map<String, dynamic> root;
      if (await f.exists()) {
        root = (jsonDecode(await f.readAsString()) as Map)
            .cast<String, dynamic>();
      } else {
        root = {};
      }

      // block 引用 -> flatBlocks 索引（identity map：BookBlock 未重写 ==/hashCode）
      final idx = <BookBlock, int>{};
      for (var i = 0; i < flatBlocks.length; i++) {
        idx[flatBlocks[i]] = i;
      }

      List<Map<String, dynamic>> encodeEntries(List<PageEntry> entries) => [
        for (final e in entries)
          // 理论上必命中：pages/cur 的 block 引用来自 flatBlocks
          {'i': idx[e.block] ?? 0, 'p': e.partialText},
      ];

      // LRU 提升：先删后加，使刚写入的 key 排到末尾
      root.remove(key);
      final entry = <String, dynamic>{
        'ratios': ratios,
        'pages': [
          for (final p in pages)
            {'first': p.firstBlockIndex, 'entries': encodeEntries(p.entries)},
        ],
        'partial': partial,
      };
      if (partial) {
        entry['resume'] = resumeBlockIndex ?? 0;
        entry['cur'] = encodeEntries(cur ?? const <PageEntry>[]);
        entry['curFirst'] = curFirst ?? 0;
        entry['remaining'] = remaining ?? 0.0;
      }
      root[key] = entry;

      // 超出上限：淘汰最旧（Map 按插入序，首部即最旧）
      while (root.length > _maxEntriesPerBook) {
        root.remove(root.keys.first);
      }

      await f.writeAsString(jsonEncode(root));
    } catch (_) {
      // 写缓存失败不影响阅读
    }
  }
}

class _PageDecodeArgs {
  final String raw;
  final String key;
  const _PageDecodeArgs(this.raw, this.key);
}

/// isolate 入口：仅 jsonDecode + 取命中条目的 raw Map。
/// 不在此重建 pages——避免 compute 跨 isolate 传值深拷贝 flatBlocks 导致
/// 返回的 block 与主线程原实例 identity 不同（read 后再 write 的 idx 全退化 0）。
/// 重建交回主线程 [_restorePages]，用 content.flatBlocks 原实例。
Map<String, dynamic>? _decodeRawEntry(_PageDecodeArgs args) {
  try {
    final root = jsonDecode(args.raw) as Map<String, dynamic>;
    return root[args.key] as Map<String, dynamic>?;
  } catch (_) {
    return null;
  }
}

/// 把缓存条目还原成 pages + ratios（+ partial 状态）。任一索引越界 / 解析失败
/// 返回 null（丢弃缓存，调用方回退重排）。用 [flat]（主线程 content.flatBlocks）
/// 重建 block 引用，保证 identity 与主线程一致。
({
  List<BookPage> pages,
  Map<String, double> ratios,
  bool partial,
  int? resumeBlockIndex,
  List<PageEntry>? cur,
  int? curFirst,
  double? remaining,
})?
_restorePages(Map<String, dynamic> entry, List<BookBlock> flat) {
  try {
    final ratiosRaw = entry['ratios'] as Map<String, dynamic>? ?? {};
    final ratios = <String, double>{};
    ratiosRaw.forEach((k, v) => ratios[k] = (v as num).toDouble());

    // 旧缓存无 partial 字段 -> 视为整本（false），兼容历史缓存
    final partial = (entry['partial'] as bool?) ?? false;

    // 越界返回 null（哨兵）：调用方见 null 即丢弃整条缓存
    List<PageEntry>? restoreEntries(List raw) {
      final entries = <PageEntry>[];
      for (final e in raw) {
        final em = e as Map<String, dynamic>;
        final i = em['i'] as int;
        if (i < 0 || i >= flat.length) return null; // 越界 -> 丢弃
        final partialText = em['p'] as String?;
        entries.add(PageEntry(flat[i], partialText: partialText));
      }
      return entries;
    }

    final pagesRaw = entry['pages'] as List;
    final pages = <BookPage>[];
    for (final p in pagesRaw) {
      final pm = p as Map<String, dynamic>;
      final first = pm['first'] as int;
      final entries = restoreEntries(pm['entries'] as List);
      if (entries == null) return null; // 越界 -> 丢弃
      pages.add(BookPage(firstBlockIndex: first, entries: entries));
    }

    List<PageEntry>? cur;
    int? curFirst;
    double? remaining;
    int? resumeBlockIndex;
    if (partial) {
      resumeBlockIndex = entry['resume'] as int?;
      final curRaw = entry['cur'] as List? ?? const [];
      cur = restoreEntries(curRaw);
      if (cur == null) return null; // 越界 -> 丢弃
      curFirst = entry['curFirst'] as int?;
      remaining = (entry['remaining'] as num?)?.toDouble();
    }

    return (
      pages: pages,
      ratios: ratios,
      partial: partial,
      resumeBlockIndex: resumeBlockIndex,
      cur: cur,
      curFirst: curFirst,
      remaining: remaining,
    );
  } catch (_) {
    return null;
  }
}
