// 漫画人源（动漫屋 dm5 系）实现。
//
// 接口链路（详见 manhuaren_config.dart）：
//   搜索：GET search.ashx?t={q}&language=1&isremovehtml=1 -> 裸 JSON 数组
//   分类页1：GET /manhua-{slug}/ -> HTML SSR（10 条）
//   分类页2+：POST dm5.ashx?action=getclasscomics&pageindex=N -> JSON
//   详情+章节：GET /manhua-{slug}/ -> HTML SSR（章节列表内联，多分组）
//   章节图：GET /m{cid}/ -> HTML 内 Dean-Edwards packer eval，解包得 var newImgs=[]
//
// Dean-Edwards packer 是 token 替换式混淆（base-N 索引到 k[] 关键词映射），
// 不是加密：解包只需解析 packer 调用参数（payload、基数、词表），按基数重构
// token 并按词表替换，得到原始 JS 字符串文本；再从其中 regex 提取目标数组。
// 纯 Dart，无 JS 引擎依赖。

import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:html/dom.dart';
import 'package:html/parser.dart';

import 'manga_source.dart';
import 'manhuaren_config.dart';
import 'models.dart';

void _log(String message) {
  if (kDebugMode) {
    debugPrint('[ManhuarenSource] $message');
  }
}

class ManhuarenSource extends MangaSource {
  final ManhuarenConfig config;
  ManhuarenSource(this.config);

  final Dio _dio = Dio(
    BaseOptions(
      connectTimeout: const Duration(seconds: 15),
      receiveTimeout: const Duration(seconds: 30),
      followRedirects: true,
    ),
  );

  @override
  String get id => config.id;

  @override
  String get name => '漫画人';

  @override
  String get lang => 'zh';

  @override
  bool get supportsLatest => false;

  @override
  bool get supportsCategories => config.categories.isNotEmpty;

  @override
  Map<String, String> get imageHeaders => {'User-Agent': config.ua};

  @override
  String? get referer => config.base;

  /// 章节图 CDN 防盗链要求 Referer=该章节页 URL（站点首页会被 403）。
  /// [ReaderPage]/[DownloadService] 用本方法取每章独立 Referer。
  @override
  String? refererForChapter(CChapter chapter) =>
      chapter.url ?? _resolveUrl(chapter.id);

  String _resolveUrl(String relOrAbs, [String? base]) {
    if (relOrAbs.startsWith('http://') || relOrAbs.startsWith('https://')) {
      return relOrAbs;
    }
    return Uri.parse(base ?? config.base).resolve(relOrAbs).toString();
  }

  /// 请求 HTML/JSON，返回原始 bytes（按 utf-8 解码；manhuaren 全站 utf-8）。
  Future<String> _fetchText(
    String url, {
    String method = 'GET',
    Map<String, dynamic>? query,
    Map<String, dynamic>? formData,
  }) async {
    final resp = await _dio.request<dynamic>(
      url,
      data: formData != null ? FormData.fromMap(formData) : null,
      queryParameters: query,
      options: Options(
        method: method,
        headers: {...imageHeaders, 'Referer': config.base},
        responseType: ResponseType.bytes,
      ),
    );
    final bytes = (resp.data as List?)?.cast<int>() ?? const <int>[];
    return utf8.decode(bytes, allowMalformed: true);
  }

  // ===== 搜索 =====

  @override
  Future<MangasPage> search(
    String query, {
    int page = 0,
    FilterList filters = const FilterList(),
  }) async {
    final s = config.search;
    final url = _resolveUrl(s.path);
    final raw = await _fetchText(
      url,
      query: {
        s.queryKey: query,
        s.languageKey: s.languageValue,
        s.removeHtmlKey: s.removeHtmlValue,
      },
    );
    // search.ashx 返回裸 JSON 数组（非对象），手动解析避免反引号边界问题。
    final trimmed = raw.trim();
    if (!trimmed.startsWith('[')) {
      _log('搜索返回非数组: ${trimmed.substring(0, trimmed.length.clamp(0, 80))}');
      return const MangasPage(items: [], hasNextPage: false);
    }
    final arr = _parseJsonArray(trimmed);
    final f = s.fields;
    final items = <CManga>[];
    for (final item in arr) {
      if (item is! Map<String, dynamic>) continue;
      final mhUrl = (item[f['url']] ?? '').toString();
      if (mhUrl.isEmpty) continue;
      items.add(
        CManga(
          id: mhUrl,
          sourceId: id,
          title: (item[f['title']] ?? '').toString(),
          author: '',
          url: _resolveUrl('/$mhUrl/'),
          initialized: false,
        ),
      );
    }
    _log('搜索 "$query": ${items.length} 条');
    // search.ashx 一次返回全部匹配（站点不分页），hasNextPage=false。
    return MangasPage(items: items, hasNextPage: false);
  }

  @override
  Future<MangasPage> getPopular({int page = 0}) async =>
      const MangasPage(items: [], hasNextPage: false);

  @override
  Future<MangasPage> getLatestUpdates({int page = 0}) async =>
      const MangasPage(items: [], hasNextPage: false);

  // ===== 分类 =====

  @override
  Future<List<FilterGroup>> fetchCategories() async {
    if (config.categories.isEmpty) return const [];
    return [
      FilterGroup(
        key: 'theme',
        title: '题材',
        options: config.categories,
        selected: config.categories.first,
      ),
    ];
  }

  @override
  Future<MangasPage> getCategoryList(
    List<FilterGroup> groups, {
    int page = 0,
  }) async {
    final cat = config.category;
    // 提取 theme slug
    final themeGroup = groups.where((g) => g.key == 'theme').firstOrNull;
    final slug = themeGroup?.selected?.value ?? config.categories.first.value;

    if (page == 0) {
      // 第1页：HTML SSR
      final path = cat.firstPagePath.replaceAll('{slug}', slug);
      final html = await _fetchText(_resolveUrl(path));
      final doc = parse(html);
      final items = <CManga>[];
      for (final li in doc.querySelectorAll(cat.htmlListItemDom)) {
        final href = li.querySelector(cat.htmlUrlDom)?.attributes['href'] ?? '';
        if (href.isEmpty || href.startsWith('javascript:')) continue;
        var title = li.querySelector(cat.htmlTitleDom)?.text.trim() ?? '';
        final coverEl = li.querySelector(cat.htmlCoverDom);
        String cover = '';
        if (coverEl != null) {
          cover = _imgUrl(coverEl) ?? '';
        }
        items.add(
          CManga(
            id: href,
            sourceId: id,
            title: title,
            cover: cover.isEmpty ? '' : _resolveUrl(cover, _resolveUrl(path)),
            url: _resolveUrl(href, _resolveUrl(path)),
          ),
        );
      }
      _log('分类[$slug] 页1: ${items.length} 条');
      return MangasPage(
        items: items,
        hasNextPage: items.length >= config.categoryPageSize,
      );
    }

    // 第2+ 页：POST dm5.ashx?action=getclasscomics（JSON）
    final tagId = cat.slugToTagId[slug] ?? '0';
    final query = <String, dynamic>{
      'action': cat.action,
      cat.pageKey: '${page + 1}',
      cat.sizeKey: '${config.categoryPageSize}',
      cat.tagIdKey: tagId,
      ...cat.fixedParams,
    };
    final raw = await _fetchText(
      _resolveUrl(cat.nextPagePath),
      method: 'POST',
      query: query,
    );
    final body = _parseJsonObject(raw);
    final list = (body[cat.listField] as List?) ?? const [];
    final f = cat.itemFields;
    final items = <CManga>[];
    for (final item in list) {
      if (item is! Map<String, dynamic>) continue;
      final urlKey = (item[f['url']] ?? '').toString();
      if (urlKey.isEmpty) continue;
      items.add(
        CManga(
          id: '/$urlKey/',
          sourceId: id,
          title: (item[f['title']] ?? '').toString(),
          cover: (item[f['cover']] ?? '').toString(),
          url: _resolveUrl('/$urlKey/'),
        ),
      );
    }
    _log('分类[$slug] 页${page + 1}: ${items.length} 条');
    return MangasPage(
      items: items,
      hasNextPage: items.length >= config.categoryPageSize,
    );
  }

  // ===== 详情 + 章节 =====

  @override
  Future<({CManga manga, List<CChapter> chapters})> getMangaDetailsAndChapters(
    CManga manga,
  ) async {
    final detailUrl = _resolveUrl(manga.id);
    final html = await _fetchText(detailUrl);
    final doc = parse(html);

    // 详情字段补全
    String title = manga.title;
    final titleEl = doc.querySelector(config.detail.titleDom);
    if (titleEl != null && titleEl.text.trim().isNotEmpty) {
      title = titleEl.text.trim();
    }
    String cover = manga.cover;
    final coverEl = doc.querySelector(config.detail.coverDom);
    if (coverEl != null) {
      final c = _imgUrl(coverEl);
      if (c != null && c.isNotEmpty) cover = c;
    }
    String? author = manga.author;
    final authorEl = doc.querySelector(config.detail.authorDom);
    if (authorEl != null && authorEl.text.trim().isNotEmpty) {
      author = authorEl.text.trim().replaceFirst(RegExp(r'^作者[:：\s]*'), '');
    }
    String? description = manga.description;
    final descEl = doc.querySelector(config.detail.descDom);
    if (descEl != null && descEl.text.trim().isNotEmpty) {
      description = descEl.text.trim();
    }
    final tagEls = doc.querySelectorAll(config.detail.tagDom);
    final tags = tagEls
        .map((e) => e.text.trim())
        .where((t) => t.isNotEmpty)
        .toList();

    // 章节列表：多分组（连载/番外），每组 ul[id^=detail-list-select-N]
    final chapters = <CChapter>[];
    final seen = <String>{};
    var order = 0;
    for (final groupUl in doc.querySelectorAll(config.detail.chapterGroupDom)) {
      for (final li in groupUl.querySelectorAll(config.detail.chapterItemDom)) {
        final a = li.querySelector(config.detail.chapterLinkDom);
        if (a == null) continue;
        final href = a.attributes['href'] ?? '';
        if (href.isEmpty || href.startsWith('javascript:')) continue;
        final chapterUrl = _resolveUrl(href, detailUrl);
        if (!seen.add(chapterUrl)) continue;
        // 章节名优先 chapterNameDom，空时回退 a.text
        var name = '';
        final nameEl = li.querySelector(config.detail.chapterNameDom);
        if (nameEl != null) name = nameEl.text.trim();
        if (name.isEmpty) name = a.text.trim();
        // 章节日期
        DateTime? createTime;
        final dateEl = li.querySelector(config.detail.chapterDateDom);
        if (dateEl != null) {
          createTime = _parseDate(dateEl.text.trim());
        }
        chapters.add(
          CChapter(
            id: chapterUrl,
            sourceId: id,
            mangaId: manga.id,
            name: name,
            url: chapterUrl,
            order: order++,
            createTime: createTime,
          ),
        );
      }
    }
    // 默认按 DOM 顺序（连载在前，章序升序）。详情页章节列表本身已按时间倒序排列，
    // 站点 updateJS 提供「正序/倒序」切换但默认展示最新在前——对齐读者期望，反转使第1话在前。
    chapters.sort((a, b) => a.order.compareTo(b.order));
    final chaptersReversed = chapters.reversed.toList();
    for (var i = 0; i < chaptersReversed.length; i++) {
      final ch = chaptersReversed[i];
      chaptersReversed[i] = CChapter(
        id: ch.id,
        sourceId: ch.sourceId,
        mangaId: ch.mangaId,
        name: ch.name,
        url: ch.url,
        order: i,
        createTime: ch.createTime,
      );
    }
    _log('详情+章节: $detailUrl, 章节数 ${chaptersReversed.length}');
    return (
      manga: manga.copyWith(
        title: title,
        cover: cover,
        author: author,
        description: description,
        tags: tags,
        url: detailUrl,
        initialized: true,
      ),
      chapters: chaptersReversed,
    );
  }

  @override
  Future<CManga> getMangaDetails(CManga manga) async =>
      (await getMangaDetailsAndChapters(manga)).manga;

  @override
  Future<List<CChapter>> getChapterList(CManga manga) async =>
      (await getMangaDetailsAndChapters(manga)).chapters;

  // ===== 章节图（Dean-Edwards packer 解包） =====

  @override
  Future<List<String>> getChapterImages(CManga manga, CChapter chapter) async {
    final url = chapter.url ?? _resolveUrl(chapter.id);
    final html = await _fetchText(url);

    // 章节图在 Dean-Edwards packer 块内（var newImgs=[...]）。
    // 付费章节页 / 版权下架页 HTML 内都无 packer（站点仅对免费可读章节注入图片 JS），
    // 故「无 packer」=不可读，优雅降级为空数组，不依赖 win-pay / 已不再提供 等文案
    // （这些文案在免费可读页的隐藏弹窗里也存在，会误判）。
    final urls = _extractPackedImages(html);
    if (urls.isEmpty) {
      _log('取图无 packer / 解包失败（视为不可读）: $url');
    } else {
      _log('取图: $url, ${urls.length} 张');
    }
    return urls;
  }

  /// 从 HTML 中找到 Dean-Edwards packer 块并解包，提取图片 URL 数组。
  List<String> _extractPackedImages(String html) {
    // packer 形如：eval(function(p,a,c,k,e,d){ ...含嵌套{}的函数体... }(
    //   'payload',radix,counter,'k0|k1|...'.split('|'),0,{}))
    // 函数体含嵌套 }，故用 .*? 惰性 + dotAll 跨过去直达数据调用段；
    // payload 内含 \' 等 JS 转义，用 (?:[^'\\]|\\.)* 兼容。
    final re = RegExp(
      r"eval\(function\(p,a,c,k,e,d\).*?\('((?:[^'\\]|\\.)*)',\s*(\d+),\s*(\d+),\s*'([^']*)'",
      dotAll: true,
    );
    for (final m in re.allMatches(html)) {
      final payload = m.group(1)!;
      final radix = int.tryParse(m.group(2)!) ?? 10;
      final kRaw = m.group(4)!;
      final unpacked = _unpack(payload, radix, kRaw);
      final urls = _extractVarArray(
        unpacked,
        config.chapterImage.imageArrayVar,
      );
      if (urls.isNotEmpty) return urls;
    }
    return const [];
  }

  /// Dean-Edwards packer 解包：payload 是压缩字符串，token 按基数分隔，
  /// 每个 token 是关键词索引（base-radix 编码）；空 token 表示字面该位置。
  /// 解包步骤：分割 payload -> 每个非空 token 用 k[idx] 替换（idx=token 转 int(radix)）。
  String _unpack(String payload, int radix, String kRaw) {
    final k = kRaw.split('|');
    return payload.replaceAllMapped(RegExp(r'\b\w+\b'), (m) {
      final tok = m.group(0)!;
      final idx = _parseBaseN(tok, radix);
      if (idx == null) return tok;
      if (idx < 0 || idx >= k.length) return tok;
      final repl = k[idx];
      return repl.isEmpty ? tok : repl;
    });
  }

  /// base-N 解码（N 可 >36，对齐 Dean-Edwards packer：0-9 数字、a-z=10..35、A-Z=36..61）。
  /// Dart 内置 int.tryParse 仅支持 2..36，故手写支持到 62。
  int? _parseBaseN(String s, int radix) {
    if (s.isEmpty) return null;
    var v = 0;
    for (final ch in s.codeUnits) {
      int d;
      if (ch >= 48 && ch <= 57) {
        d = ch - 48; // 0-9
      } else if (ch >= 97 && ch <= 122) {
        d = ch - 97 + 10; // a-z
      } else if (ch >= 65 && ch <= 90) {
        d = ch - 65 + 36; // A-Z
      } else {
        return null;
      }
      if (d >= radix) return null;
      v = v * radix + d;
    }
    return v;
  }

  /// 从解包后的 JS 文本中提取 var {name}=[...] 字符串数组。
  List<String> _extractVarArray(String js, String name) {
    // packer 解包后得到的 JS 文本里仍含 JS 转义（\' -> '、\\ -> \），
    // 对 URL 提取无影响但会让正则匹配字面量边界紊乱（首尾的 \' 让正则
    // 误判字符串起点）。先做一轮整体转义还原，再 regex 提取。
    final unescaped = _unescapeJsString(js);
    final re = RegExp(
      r"var\s+" + RegExp.escape(name) + r"\s*=\s*\[(.*?)\]",
      dotAll: true,
    );
    final m = re.firstMatch(unescaped);
    if (m == null) return const [];
    final body = m.group(1)!;
    // 数组元素为 '...' 单引号字符串，逗号分隔。经 _unescapeJsString 还原后元素间无转义干扰。
    final itemRe = RegExp(r"'((?:[^'\\]|\\.)*)'");
    return itemRe
        .allMatches(body)
        .map((m) => m.group(1)!)
        .where((s) => s.isNotEmpty && !s.startsWith('data:'))
        .map(
          (s) => config.chapterImage.ensureHttps && s.startsWith('//')
              ? 'https:$s'
              : s,
        )
        .toList();
  }

  /// JS 字符串转义还原（\' \\ \n \t \uXXXX 等常见）。
  String _unescapeJsString(String s) {
    return s
        .replaceAll(r"\'", "'")
        .replaceAll(r'\"', '"')
        .replaceAll(r'\\', r'\')
        .replaceAll(r'\n', '\n')
        .replaceAll(r'\t', '\t')
        .replaceAllMapped(RegExp(r'\\u([0-9a-fA-F]{4})'), (m) {
          final code = int.parse(m.group(1)!, radix: 16);
          return String.fromCharCode(code);
        });
  }

  // ===== 通用工具 =====

  /// 取图片真实 URL：依次试 src/data-src/data-original/data-lazy-src。
  String? _imgUrl(Element? el) {
    if (el == null) return null;
    for (final attr in const [
      'src',
      'data-src',
      'data-original',
      'data-lazy-src',
    ]) {
      final v = el.attributes[attr];
      if (v != null && v.isNotEmpty && !v.startsWith('data:')) return v;
    }
    return el.attributes['src'];
  }

  /// 解析 "2016-11-11" / "2026-08-10 15:30" 等日期。
  DateTime? _parseDate(String s) {
    if (s.isEmpty) return null;
    final re = RegExp(r'(\d{4})-(\d{2})-(\d{2})');
    final m = re.firstMatch(s);
    if (m == null) return null;
    final y = int.tryParse(m.group(1)!);
    final mo = int.tryParse(m.group(2)!);
    final d = int.tryParse(m.group(3)!);
    if (y == null || mo == null || d == null) return null;
    try {
      return DateTime(y, mo, d);
    } catch (_) {
      return null;
    }
  }

  // ===== 轻量 JSON 解析 =====
  // dio 的 responseType.bytes 拿不到自动 JSON 解析；为避免双重请求与类型边界，
  // 用 flutter 内置 dart:convert。

  List _parseJsonArray(String raw) {
    try {
      return jsonDecode(raw) as List;
    } catch (e) {
      _log('JSON 数组解析失败: $e');
      return const [];
    }
  }

  Map<String, dynamic> _parseJsonObject(String raw) {
    try {
      final v = jsonDecode(raw);
      if (v is Map<String, dynamic>) return v;
      if (v is Map) return v.cast<String, dynamic>();
      return const {};
    } catch (e) {
      _log('JSON 对象解析失败: $e');
      return const {};
    }
  }
}
