import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

import '../models/book_content.dart';

/// 解析结果（[BookContent]）的磁盘缓存：把 EPUB/TXT 解析后的章节结构 + 图片字节
/// 持久化，命中时跳过 [BookParser] 的 compute 解析（EPUB 解压 + XML 约数百 ms ~ 1s+）。
///
/// 缓存键为文件指纹（size + mtime）：重新下载通常 mtime 变化 -> miss 重解析。
/// 同一 bookId 仅保留最新版本（单条目）。
///
/// 大书（缓存 >1MB）的 JSON 解码 / 编码在后台 isolate 执行，避免卡 UI 线程。
class BookContentCacheService {
  BookContentCacheService._();
  static final BookContentCacheService instance = BookContentCacheService._();

  /// 触发 isolate 解码的缓存大小阈值。
  static const _isolateThreshold = 1 << 20; // 1MB

  Future<File> _file(String bookId) async {
    final dir = await getApplicationSupportDirectory();
    final cacheDir = Directory('${dir.path}/book_content_cache');
    if (!await cacheDir.exists()) await cacheDir.create(recursive: true);
    return File('${cacheDir.path}/$bookId.json');
  }

  /// 文件指纹：size + 修改时间(ms)。用于判断缓存是否仍有效，避免读文件算 hash。
  Future<String> fingerprintOf(File file) async {
    final stat = await file.stat();
    return '${stat.size}_${stat.modified.millisecondsSinceEpoch}';
  }

  /// 读缓存。指纹不匹配 / 解析失败返回 null（调用方回退重新解析）。
  /// 大书（>1MB）在 isolate 解码，避免 jsonDecode + 重建对象卡 UI 线程。
  Future<BookContent?> read({
    required String bookId,
    required String fingerprint,
  }) async {
    try {
      final f = await _file(bookId);
      if (!await f.exists()) return null;
      final raw = await f.readAsString();
      final args = _DecodeArgs(raw, fingerprint);
      if (raw.length > _isolateThreshold) {
        return compute(_decodeContentCache, args);
      }
      return _decodeContentCache(args);
    } catch (_) {
      return null;
    }
  }

  /// 写缓存。编码（含图片 base64）在 isolate 执行；失败静默忽略，不影响阅读。
  Future<void> write({
    required String bookId,
    required String fingerprint,
    required BookContent content,
  }) async {
    try {
      final f = await _file(bookId);
      final json = await compute(
        _encodeContentCache,
        _EncodeArgs(fingerprint, content),
      );
      await f.writeAsString(json);
    } catch (_) {
      // 写缓存失败不影响阅读
    }
  }
}

class _DecodeArgs {
  final String raw;
  final String fingerprint;
  const _DecodeArgs(this.raw, this.fingerprint);
}

class _EncodeArgs {
  final String fingerprint;
  final BookContent content;
  const _EncodeArgs(this.fingerprint, this.content);
}

/// isolate 入口：jsonDecode + 重建 BookContent。指纹不匹配返回 null。
BookContent? _decodeContentCache(_DecodeArgs args) {
  try {
    final root = jsonDecode(args.raw) as Map<String, dynamic>;
    if (root['fp'] != args.fingerprint) return null;
    return _decodeContent(root['content'] as Map<String, dynamic>);
  } catch (_) {
    return null;
  }
}

/// isolate 入口：编码 BookContent 为 JSON 字符串。
String _encodeContentCache(_EncodeArgs args) {
  final root = {
    'fp': args.fingerprint,
    'content': _encodeContent(args.content),
  };
  return jsonEncode(root);
}

Map<String, dynamic> _encodeContent(BookContent c) => {
  'title': c.title,
  'author': c.author,
  'chapters': [
    for (final ch in c.chapters)
      {
        'title': ch.title,
        'blocks': [for (final b in ch.blocks) _encodeBlock(b)],
      },
  ],
  'images': {for (final e in c.images.entries) e.key: base64Encode(e.value)},
};

BookContent _decodeContent(Map<String, dynamic> m) {
  final chaptersRaw = m['chapters'] as List;
  final chapters = <BookChapter>[];
  for (final ch in chaptersRaw) {
    final chm = ch as Map<String, dynamic>;
    final blocksRaw = chm['blocks'] as List;
    final blocks = <BookBlock>[];
    for (final b in blocksRaw) {
      final bm = b as Map<String, dynamic>;
      switch (bm['t'] as String) {
        case 'p':
          blocks.add(ParagraphBlock(bm['x'] as String));
        case 'h':
          blocks.add(HeadingBlock(bm['x'] as String, bm['l'] as int));
        case 'i':
          blocks.add(ImageBlock(bm['k'] as String));
        default: // 'r'
          blocks.add(const DividerBlock());
      }
    }
    chapters.add(BookChapter(title: chm['title'] as String, blocks: blocks));
  }
  final imagesRaw = m['images'] as Map<String, dynamic>? ?? {};
  final images = <String, Uint8List>{};
  imagesRaw.forEach((k, v) {
    images[k] = base64Decode(v as String);
  });
  return BookContent(
    title: m['title'] as String,
    author: m['author'] as String?,
    chapters: chapters,
    images: images,
  );
}

Map<String, dynamic> _encodeBlock(BookBlock b) {
  if (b is ParagraphBlock) return {'t': 'p', 'x': b.text};
  if (b is HeadingBlock) return {'t': 'h', 'x': b.text, 'l': b.level};
  if (b is ImageBlock) return {'t': 'i', 'k': b.imageKey};
  return {'t': 'r'}; // DividerBlock
}
