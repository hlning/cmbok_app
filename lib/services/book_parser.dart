import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:html/dom.dart' as html;
import 'package:html/parser.dart' show parse;
import 'package:kindle_unpack/kindle_unpack.dart';
import 'package:xml/xml.dart';

import '../models/book_content.dart';
import '../services/platform_service.dart';

/// 解析 EPUB / MOBI / TXT 为 [BookContent]。
/// - EPUB：archive 解 zip + xml 解 container.xml / OPF / XHTML（含 NAV/NCX 目录）。
/// - MOBI/AZW/AZW3：[KindleBook] 转 EPUB 字节后复用 EPUB 解析（kindle_unpack，GPL v3）。
/// - TXT：UTF-8 优先，回退系统编码（Windows 中文为 GBK），再回退容错 UTF-8。
class BookParser {
  BookParser._();

  /// 解析 EPUB 文件。
  static Future<BookContent> parseEpub(File file) async =>
      parseEpubBytes(await file.readAsBytes());

  /// 解析 PDF：调原生 PdfRenderer 取页数 + 每页尺寸，构造每页一个 [ImageBlock]，
  /// 图片字节按需光栅化（[BookContent.imageLoader]）。主线程执行——channel 不可在
  /// isolate，故不走 [compute]（与 EPUB/MOBI/TXT 不同）。
  static Future<BookContent> parsePdf(File file) async {
    final info = await PlatformService.pdfOpen(file.path);
    if (info == null || info.pageCount <= 0) {
      throw const FormatException('无法打开 PDF（可能已损坏或加密）');
    }
    final name = file.uri.pathSegments.last;
    final dot = name.lastIndexOf('.');
    final title = dot > 0 ? name.substring(0, dot) : name;
    final blocks = <BookBlock>[];
    for (var i = 0; i < info.pageCount; i++) {
      final s = info.sizes[i];
      blocks.add(ImageBlock('pdf_page_$i', aspectRatio: s.w / s.h));
    }
    final path = file.path;
    return BookContent(
      title: title,
      // 空章节标题：flatBlocks 不插 HeadingBlock，使 blockIndex == PDF 页码，
      // 与旧 PdfReaderPage 进度（blockIndex=页码）兼容，且不多占标题页。
      chapters: [BookChapter(title: '', blocks: blocks)],
      images: <String, Uint8List>{},
      imageLoader: (key, targetWidth) async {
        final idx = int.tryParse(key.substring('pdf_page_'.length)) ?? 0;
        final bytes = await PlatformService.pdfRenderPage(
          path,
          idx,
          targetWidth.round(),
        );
        if (bytes == null) {
          throw Exception('PDF 第${idx + 1}页渲染失败');
        }
        return bytes;
      },
    );
  }

  /// 解析 EPUB 字节（[parseEpub] 的核心；MOBI 经 [KindleBook.toEpub] 转出
  /// EPUB 字节后直接复用，避免二次读盘）。
  static BookContent parseEpubBytes(Uint8List bytes) {
    final archive = ZipDecoder().decodeBytes(bytes);

    // 归一化条目：精确名 -> bytes，附小写名 -> 精确名（大小写回退）
    final entries = <String, Uint8List>{};
    final lowerToName = <String, String>{};
    for (final f in archive) {
      if (!f.isFile) continue;
      final name = f.name;
      final data = _bytesOfFile(f);
      entries[name] = data;
      lowerToName[name.toLowerCase()] = name;
    }

    Uint8List? entryOf(String path) {
      final e = entries[path];
      if (e != null) return e;
      final real = lowerToName[path.toLowerCase()];
      return real == null ? null : entries[real];
    }

    // 1) container.xml -> OPF 路径
    final containerXml = entryOf('META-INF/container.xml');
    if (containerXml == null) {
      throw const FormatException('缺少 META-INF/container.xml');
    }
    final container = XmlDocument.parse(utf8.decode(containerXml));
    final rootFileEl = container
        .findAllElements('rootfile', namespace: '*')
        .firstOrNull;
    final opfPath = rootFileEl?.getAttribute('full-path');
    if (opfPath == null || opfPath.isEmpty) {
      throw const FormatException('container.xml 未声明 OPF 路径');
    }
    final opfDir = _dirOf(opfPath);
    final opfBytes = entryOf(opfPath);
    if (opfBytes == null) throw FormatException('OPF 不存在：$opfPath');
    final opf = XmlDocument.parse(utf8.decode(opfBytes));

    // 2) metadata
    String? title;
    final titleEl = opf.findAllElements('title', namespace: '*').firstOrNull;
    if (titleEl != null) title = titleEl.innerText.trim();
    String? author;
    final creatorEl = opf
        .findAllElements('creator', namespace: '*')
        .firstOrNull;
    if (creatorEl != null) author = creatorEl.innerText.trim();

    // 3) manifest：id -> {href, mediaType, properties}
    final manifest = <String, _ManifestItem>{};
    for (final item in opf.findAllElements('item', namespace: '*')) {
      final id = item.getAttribute('id');
      final href = item.getAttribute('href');
      if (id == null || href == null) continue;
      manifest[id] = _ManifestItem(
        href: href,
        resolvedHref: _resolve(opfDir, href),
        mediaType: item.getAttribute('media-type') ?? '',
        properties: item.getAttribute('properties') ?? '',
      );
    }

    // 4) spine 顺序
    final spine = opf.findAllElements('spine', namespace: '*').firstOrNull;
    final idrefs = <String>[];
    if (spine != null) {
      for (final itemref in spine.findElements('itemref', namespace: '*')) {
        final idref = itemref.getAttribute('idref');
        if (idref != null && manifest.containsKey(idref)) idrefs.add(idref);
      }
    }
    if (idrefs.isEmpty) {
      // 无 spine 则按 manifest 中 XHTML 顺序兜底
      for (final entry in manifest.entries) {
        if (entry.value.mediaType.contains('xhtml')) idrefs.add(entry.key);
      }
    }

    // 5) 目录：文件 -> 标题（NAV 优先，其次 NCX）
    final tocMap = _buildTocMap(opf, manifest, entryOf);

    // 6) 图片资源入 images map
    final images = <String, Uint8List>{};
    for (final item in manifest.values) {
      if (item.mediaType.startsWith('image/')) {
        final data = entryOf(item.resolvedHref);
        if (data != null) images[item.resolvedHref] = data;
      }
    }

    // 7) 按 spine 顺序解每个 XHTML 为 chapter
    final chapters = <BookChapter>[];
    for (var i = 0; i < idrefs.length; i++) {
      final item = manifest[idrefs[i]]!;
      if (!item.mediaType.contains('xhtml') &&
          !item.resolvedHref.toLowerCase().endsWith('.xhtml') &&
          !item.resolvedHref.toLowerCase().endsWith('.html') &&
          !item.resolvedHref.toLowerCase().endsWith('.htm')) {
        continue;
      }
      final xhtmlBytes = entryOf(item.resolvedHref);
      if (xhtmlBytes == null) continue;
      final docBaseDir = _dirOf(item.resolvedHref);
      final blocks = <BookBlock>[];
      try {
        final doc = XmlDocument.parse(utf8.decode(xhtmlBytes));
        final body = doc.findAllElements('body', namespace: '*').firstOrNull;
        if (body != null) _extractBlocks(body, docBaseDir, blocks);
      } catch (_) {
        // 严格 XML 解析失败（MOBI 转出的 HTML4：无引号属性/未闭合标签等），
        // 回退 html 包容错解析，避免整书无内容可读
        final doc = parse(utf8.decode(xhtmlBytes, allowMalformed: true));
        final body = doc.querySelector('body');
        if (body != null) _extractBlocksHtml(body, docBaseDir, blocks);
      }
      if (blocks.isEmpty) continue;
      final title =
          tocMap[item.resolvedHref] ??
          (blocks.whereType<HeadingBlock>().firstOrNull?.text) ??
          '第 ${i + 1} 节';
      chapters.add(BookChapter(title: title, blocks: blocks));
    }

    if (chapters.isEmpty) throw const FormatException('EPUB 无可读内容');
    return BookContent(
      title: title ?? '未知书名',
      author: author,
      chapters: chapters,
      images: images,
    );
  }

  /// 解析 EPUB 并在同 isolate 内顺带解码图片宽高比与自然宽度。
  ///
  /// [parseEpub] 返回的 images 与 [decodeImageInfo] 在同一 isolate 串行执行，
  /// 避免 images 再单独传进另一个 isolate（compute 默认对 Uint8List 深拷贝，
  /// 图片多的 EPUB 大书来回拷贝会冻结 UI）。返回 content + ratios + naturalWidths
  /// 供调用方直接使用。
  static Future<
    ({
      BookContent content,
      Map<String, double> ratios,
      Map<String, int> naturalWidths,
    })
  >
  parseEpubWithRatios(File file) async {
    final content = await parseEpub(file);
    final info = decodeImageInfo(content.images);
    return (
      content: content,
      ratios: info.ratios,
      naturalWidths: info.naturalWidths,
    );
  }

  /// 解析 MOBI/AZW/AZW3：先用 [KindleBook] 转 EPUB 字节，再走 [parseEpubBytes]，
  /// 同一 isolate 内顺带解码图片宽高比与自然宽度（与 EPUB 路径一致，省 images 跨
  /// isolate 深拷贝）。
  static Future<
    ({
      BookContent content,
      Map<String, double> ratios,
      Map<String, int> naturalWidths,
    })
  >
  parseMobiWithRatios(File file) async {
    final bytes = await file.readAsBytes();
    final epubBytes = KindleBook.fromBytes(bytes).toEpub();
    final content = parseEpubBytes(epubBytes);
    final info = decodeImageInfo(content.images);
    return (
      content: content,
      ratios: info.ratios,
      naturalWidths: info.naturalWidths,
    );
  }

  /// 从 EPUB 提取封面图字节（不解析正文）：
  /// EPUB2 `<meta name="cover" content="<id>"/>` / EPUB3 `properties=cover-image` / 兜底首张 image。
  static Future<Uint8List?> extractEpubCover(File file) async {
    final bytes = await file.readAsBytes();
    final archive = ZipDecoder().decodeBytes(bytes);

    final entries = <String, Uint8List>{};
    final lowerToName = <String, String>{};
    for (final f in archive) {
      if (!f.isFile) continue;
      entries[f.name] = _bytesOfFile(f);
      lowerToName[f.name.toLowerCase()] = f.name;
    }
    Uint8List? entryOf(String path) {
      final e = entries[path];
      if (e != null) return e;
      final real = lowerToName[path.toLowerCase()];
      return real == null ? null : entries[real];
    }

    final containerXml = entryOf('META-INF/container.xml');
    if (containerXml == null) return null;
    final container = XmlDocument.parse(utf8.decode(containerXml));
    final rootFileEl = container
        .findAllElements('rootfile', namespace: '*')
        .firstOrNull;
    final opfPath = rootFileEl?.getAttribute('full-path');
    if (opfPath == null || opfPath.isEmpty) return null;
    final opfDir = _dirOf(opfPath);
    final opfBytes = entryOf(opfPath);
    if (opfBytes == null) return null;
    final opf = XmlDocument.parse(utf8.decode(opfBytes));

    // manifest：id -> item
    final manifest = <String, _ManifestItem>{};
    for (final item in opf.findAllElements('item', namespace: '*')) {
      final id = item.getAttribute('id');
      final href = item.getAttribute('href');
      if (id == null || href == null) continue;
      manifest[id] = _ManifestItem(
        href: href,
        resolvedHref: _resolve(opfDir, href),
        mediaType: item.getAttribute('media-type') ?? '',
        properties: item.getAttribute('properties') ?? '',
      );
    }

    // 1) EPUB2：meta name=cover -> manifest id
    String? metaCoverId;
    for (final m in opf.findAllElements('meta', namespace: '*')) {
      if (m.getAttribute('name') == 'cover') {
        metaCoverId = m.getAttribute('content');
        break;
      }
    }
    if (metaCoverId != null && manifest.containsKey(metaCoverId)) {
      final data = entryOf(manifest[metaCoverId]!.resolvedHref);
      if (data != null) return data;
    }
    // 2) EPUB3：properties 含 cover-image
    for (final item in manifest.values) {
      if (item.properties.split(' ').contains('cover-image')) {
        final data = entryOf(item.resolvedHref);
        if (data != null) return data;
      }
    }
    // 3) 兜底：manifest 第一张 image
    for (final item in manifest.values) {
      if (item.mediaType.startsWith('image/')) {
        final data = entryOf(item.resolvedHref);
        if (data != null) return data;
      }
    }
    return null;
  }

  /// 从 MOBI/AZW/AZW3 提取封面图字节（不解析正文）：
  /// [KindleBook.images.cover] 由 EXTH 201 指向，直接取其原始字节。
  static Future<Uint8List?> extractMobiCover(File file) async {
    final bytes = await file.readAsBytes();
    final book = KindleBook.fromBytes(bytes);
    return book.images.cover?.data;
  }

  /// 解析 TXT 文件。
  static Future<BookContent> parseTxt(File file) async {
    final bytes = await file.readAsBytes();
    String text;
    try {
      text = utf8.decode(bytes, allowMalformed: false);
    } catch (_) {
      try {
        text = systemEncoding.decode(bytes);
      } catch (_) {
        text = utf8.decode(bytes, allowMalformed: true);
      }
    }
    // 一行一段（中文 TXT 主流格式）；空行跳过；去首尾空白（含全角空格缩进）
    final blocks = <BookBlock>[];
    for (final line in text.split(RegExp(r'\r\n|\r|\n'))) {
      final t = line.trim();
      if (t.isNotEmpty) blocks.add(ParagraphBlock(t));
    }
    final title = file.uri.pathSegments.isNotEmpty
        ? file.uri.pathSegments.last
        : '未命名';
    return BookContent(
      title: title,
      chapters: [BookChapter(title: title, blocks: blocks)],
    );
  }

  /// 解析图片宽高比（宽/高）与自然像素宽度。纯 Dart 读图片头部（PNG/GIF/JPEG），
  /// 不依赖 dart:ui--instantiateImageCodec 在 compute 子 isolate 不可用会抛异常
  /// 致结果为空。故可安全在 isolate 内同步执行；SVG 等无固定像素尺寸的跳过。
  /// naturalWidths 供渲染层区分行内小图标（如"注"标记）与整页插图。
  static ({Map<String, double> ratios, Map<String, int> naturalWidths})
  decodeImageInfo(Map<String, Uint8List> images) {
    final ratios = <String, double>{};
    final naturalWidths = <String, int>{};
    for (final entry in images.entries) {
      final size = _imageNaturalSize(entry.value);
      if (size == null) continue; // 未知格式，调用方按默认比例
      final w = size.$1, h = size.$2;
      naturalWidths[entry.key] = w;
      ratios[entry.key] = h == 0 ? 1.5 : w / h;
    }
    return (ratios: ratios, naturalWidths: naturalWidths);
  }

  /// 纯 Dart 读取图片自然像素宽高（仅读头部，不解码整图）。支持 PNG / GIF / JPEG；
  /// 其他格式（SVG/WEBP 等）返回 null。
  static (int, int)? _imageNaturalSize(Uint8List b) {
    if (b.length < 24) return null;
    // PNG：IHDR 起始处 width/height 各 4 字节大端
    if (b[0] == 0x89 && b[1] == 0x50 && b[2] == 0x4E && b[3] == 0x47) {
      final w = (b[16] << 24) | (b[17] << 16) | (b[18] << 8) | b[19];
      final h = (b[20] << 24) | (b[21] << 16) | (b[22] << 8) | b[23];
      return (w, h);
    }
    // GIF：width/height 各 2 字节小端
    if (b[0] == 0x47 && b[1] == 0x49 && b[2] == 0x46) {
      if (b.length < 10) return null;
      final w = b[6] | (b[7] << 8);
      final h = b[8] | (b[9] << 8);
      return (w, h);
    }
    // JPEG：扫描 SOF marker 取宽高
    if (b[0] == 0xFF && b[1] == 0xD8) {
      var i = 2;
      while (i + 9 < b.length) {
        if (b[i] != 0xFF) {
          i++;
          continue;
        }
        final marker = b[i + 1];
        i += 2;
        // SOF0~SOF15（DHT/JPG/DAC 不是 SOF）
        if (marker >= 0xC0 &&
            marker <= 0xCF &&
            marker != 0xC4 &&
            marker != 0xC8 &&
            marker != 0xCC) {
          final h = (b[i + 3] << 8) | b[i + 4];
          final w = (b[i + 5] << 8) | b[i + 6];
          return (w, h);
        }
        if (marker == 0xD8 || marker == 0xD9) continue; // SOI/EOI 无段长度
        if (i + 1 >= b.length) break;
        final len = (b[i] << 8) | b[i + 1];
        i += len;
      }
    }
    return null;
  }

  /// 递归提取 body 下的 block：容器元素（div/section 等）下钻，
  /// 叶内容元素（p/h/img/hr/li）直接成块，避免重复。
  static void _extractBlocks(
    XmlElement parent,
    String baseDir,
    List<BookBlock> out,
  ) {
    for (final node in parent.children) {
      if (node is! XmlElement) continue;
      final tag = node.name.local.toLowerCase();
      if (tag.length == 2 && tag[0] == 'h') {
        final code = tag.codeUnitAt(1);
        if (code >= 0x31 && code <= 0x36) {
          // h1~h6
          final t = node.innerText.trim();
          if (t.isNotEmpty) out.add(HeadingBlock(t, code - 0x30));
        }
      } else if (tag == 'p' || tag == 'li' || tag == 'figcaption') {
        // MOBI 等会把 <img> 包在 <p> 里：p 作叶子只取文本会丢图，故先抽
        // 嵌套图片再取文本（仅含文本时与原行为一致，不回归）。
        for (final img in node.findAllElements('img', namespace: '*')) {
          final src = img.getAttribute('src') ?? '';
          if (src.isNotEmpty) out.add(ImageBlock(_resolve(baseDir, src)));
        }
        for (final im in node.findAllElements('image', namespace: '*')) {
          final href =
              im.getAttribute('href', namespace: '*') ??
              im.getAttribute('xlink:href') ??
              '';
          if (href.isNotEmpty) out.add(ImageBlock(_resolve(baseDir, href)));
        }
        final t = node.innerText.trim();
        if (t.isNotEmpty) out.add(ParagraphBlock(t));
      } else if (tag == 'img') {
        final src = node.getAttribute('src') ?? '';
        if (src.isNotEmpty) out.add(ImageBlock(_resolve(baseDir, src)));
      } else if (tag == 'image') {
        final href =
            node.getAttribute('href', namespace: '*') ??
            node.getAttribute('xlink:href') ??
            '';
        if (href.isNotEmpty) out.add(ImageBlock(_resolve(baseDir, href)));
      } else if (tag == 'hr') {
        out.add(const DividerBlock());
      } else if (tag == 'br') {
        // 忽略，文本自然流动
      } else if (tag == 'table') {
        // 表格扁平化为段落：每行单元格文本拼接
        for (final tr in node.findAllElements('tr', namespace: '*')) {
          final cells = [
            ...tr.findElements('td', namespace: '*'),
            ...tr.findElements('th', namespace: '*'),
          ];
          final t = cells
              .map((c) => c.innerText.trim())
              .where((s) => s.isNotEmpty)
              .join('  ');
          if (t.isNotEmpty) out.add(ParagraphBlock(t));
        }
      } else {
        _extractBlocks(node, baseDir, out);
      }
    }
  }

  /// html 包节点版的 [_extractBlocks]：当 XHTML 严格解析失败（MOBI 转出的
  /// HTML4：无引号属性、未闭合标签）时回退使用。html 包容错解析；与
  /// [_extractBlocks] 逻辑一致，仅适配 html 包 API。
  static void _extractBlocksHtml(
    html.Element parent,
    String baseDir,
    List<BookBlock> out,
  ) {
    for (final node in parent.children) {
      final tag = (node.localName ?? '').toLowerCase();
      if (tag.length == 2 && tag[0] == 'h') {
        final code = tag.codeUnitAt(1);
        if (code >= 0x31 && code <= 0x36) {
          final t = node.text.trim();
          if (t.isNotEmpty) out.add(HeadingBlock(t, code - 0x30));
        }
      } else if (tag == 'p' || tag == 'li' || tag == 'figcaption') {
        // MOBI 等会把 <img> 包在 <p> 里：p 作叶子只取文本会丢图，故先抽
        // 嵌套图片再取文本（仅含文本时与原行为一致，不回归）。
        for (final img in node.querySelectorAll('img')) {
          final src = img.attributes['src'] ?? '';
          if (src.isNotEmpty) out.add(ImageBlock(_resolve(baseDir, src)));
        }
        for (final im in node.querySelectorAll('image')) {
          final href =
              im.attributes['href'] ?? im.attributes['xlink:href'] ?? '';
          if (href.isNotEmpty) out.add(ImageBlock(_resolve(baseDir, href)));
        }
        final t = node.text.trim();
        if (t.isNotEmpty) out.add(ParagraphBlock(t));
      } else if (tag == 'img') {
        final src = node.attributes['src'] ?? '';
        if (src.isNotEmpty) out.add(ImageBlock(_resolve(baseDir, src)));
      } else if (tag == 'image') {
        final href =
            node.attributes['href'] ?? node.attributes['xlink:href'] ?? '';
        if (href.isNotEmpty) out.add(ImageBlock(_resolve(baseDir, href)));
      } else if (tag == 'hr') {
        out.add(const DividerBlock());
      } else if (tag == 'br') {
        // 忽略，文本自然流动
      } else if (tag == 'table') {
        for (final tr in node.querySelectorAll('tr')) {
          final cells = [
            ...tr.querySelectorAll('td'),
            ...tr.querySelectorAll('th'),
          ];
          final t = cells
              .map((c) => c.text.trim())
              .where((s) => s.isNotEmpty)
              .join('  ');
          if (t.isNotEmpty) out.add(ParagraphBlock(t));
        }
      } else {
        _extractBlocksHtml(node, baseDir, out);
      }
    }
  }

  /// 构建 目录：内容文件路径 -> 标题。NAV(EPUB3) 优先，其次 NCX(EPUB2)。
  static Map<String, String> _buildTocMap(
    XmlDocument opf,
    Map<String, _ManifestItem> manifest,
    Uint8List? Function(String) entryOf,
  ) {
    final map = <String, String>{};
    // NAV：properties 含 nav
    String? navId;
    for (final entry in manifest.entries) {
      if (entry.value.properties.split(' ').contains('nav')) {
        navId = entry.key;
        break;
      }
    }
    if (navId != null) {
      final navItem = manifest[navId]!;
      final navBytes = entryOf(navItem.resolvedHref);
      if (navBytes != null) {
        try {
          final doc = XmlDocument.parse(utf8.decode(navBytes));
          final navDir = _dirOf(navItem.resolvedHref);
          for (final a in doc.findAllElements('a', namespace: '*')) {
            final href = a.getAttribute('href');
            final text = a.innerText.trim();
            if (href == null || href.isEmpty || text.isEmpty) continue;
            final fileKey = _resolve(navDir, href);
            map.putIfAbsent(fileKey, () => text);
          }
        } catch (_) {
          // ignore
        }
      }
    }
    if (map.isNotEmpty) return map;
    // NCX：media-type application/x-dtbncx+xml
    String? ncxId;
    _ManifestItem? ncxItem;
    for (final entry in manifest.entries) {
      if (entry.value.mediaType.contains('x-dtbncx+xml')) {
        ncxId = entry.key;
        ncxItem = entry.value;
        break;
      }
    }
    if (ncxId != null && ncxItem != null) {
      final ncxBytes = entryOf(ncxItem.resolvedHref);
      if (ncxBytes != null) {
        try {
          final doc = XmlDocument.parse(utf8.decode(ncxBytes));
          final ncxDir = _dirOf(ncxItem.resolvedHref);
          for (final np in doc.findAllElements('navPoint', namespace: '*')) {
            final content = np
                .findElements('content', namespace: '*')
                .firstOrNull;
            final label = np
                .findAllElements('text', namespace: '*')
                .firstOrNull
                ?.innerText
                .trim();
            final src = content?.getAttribute('src');
            if (src != null &&
                src.isNotEmpty &&
                label != null &&
                label.isNotEmpty) {
              map.putIfAbsent(_resolve(ncxDir, src), () => label);
            }
          }
        } catch (_) {
          // ignore
        }
      }
    }
    return map;
  }

  /// 取 ArchiveFile 的字节（content 可能是 `Uint8List` 或 `List<int>`）
  static Uint8List _bytesOfFile(ArchiveFile f) {
    final c = f.content;
    if (c is Uint8List) return c;
    return Uint8List.fromList(c as List<int>);
  }

  /// 路径所属目录
  static String _dirOf(String path) {
    final i = path.lastIndexOf('/');
    return i < 0 ? '' : path.substring(0, i);
  }

  /// 相对路径解析：合并 baseDir + href，处理 ./ ../，去 anchor。
  static String _resolve(String baseDir, String href) {
    final h = href.split('#').first.trim();
    if (h.isEmpty) return baseDir;
    final parts = <String>[
      ...baseDir.split('/').where((s) => s.isNotEmpty),
      ...h.split('/'),
    ];
    final out = <String>[];
    for (final p in parts) {
      if (p == '.' || p.isEmpty) continue;
      if (p == '..') {
        if (out.isNotEmpty) out.removeLast();
        continue;
      }
      out.add(p);
    }
    return out.join('/');
  }
}

class _ManifestItem {
  final String href;
  final String resolvedHref;
  final String mediaType;
  final String properties;
  const _ManifestItem({
    required this.href,
    required this.resolvedHref,
    required this.mediaType,
    required this.properties,
  });
}
