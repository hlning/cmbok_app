// 配置驱动的站点源：按 SiteConfig（DOM 选择器 + 取图模式）实现 MangaSource 契约。
//
// 详情/章节用 Dio + html 包解析章节页 HTML；取图分双路径：
//   useFrame=0 直连：Dio 章节页 + imgDom/imgAttr 提取（+ 翻页，2b）
//   useFrame=1 iframe/懒加载：WebViewImageFetcher（WebView 快取 + 前缀过滤）
//
// 搜索：site.searchUrl 有则 Dio + html 解析结果；无则抛 UnsupportedSearchError，
// 由搜索页捕获并提示「用 URL 兜底入口」。

import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:html/dom.dart';
import 'package:html/parser.dart';

import 'manga_source.dart';
import 'models.dart';
import 'site_config.dart';
import 'webview_image_fetcher.dart';
import 'package:gbk_codec/gbk_codec.dart';

/// 配置源不支持搜索时抛出（UI 提示用 URL 兜底入口）。
class UnsupportedSearchError implements Exception {
  final String message;
  UnsupportedSearchError(this.message);
  @override
  String toString() => message;
}

/// 配置驱动的站点源。
class ConfigMangaSource extends MangaSource {
  final SiteConfig site;
  ConfigMangaSource(this.site);

  @override
  String get id => 'config:${site.name}';

  @override
  String get name => site.name;

  @override
  String get lang => 'zh';

  @override
  bool get supportsLatest => false;

  @override
  Map<String, String> get imageHeaders => const {
    'User-Agent':
        'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
        '(KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36',
  };

  @override
  String? get referer {
    // imgReferer: 空=site.url（默认），'none'=不发（g-mh.online 防盗链反直觉：
    // 有 Referer 重定向错误图，无 Referer 301 到 c-nd3 CDN 200），其他=自定义值
    if (site.imgReferer == 'none') return null;
    if (site.imgReferer.isNotEmpty) return site.imgReferer;
    return site.url;
  }

  @override
  bool get chapterSortByOrder => site.chapterSortByOrder;

  /// config 源 order=DOM 遍历顺序：chapterOrder=0(倒序,最新在前)时降序排得「第1话在前」，
  /// =1(正序,第1话在前)时升序。复用现有 chapterOrder 配置作方向。
  @override
  bool get chapterOrderDescending => site.chapterOrder == 0;

  void _log(String message) => debugPrint('[ConfigMangaSource:$name] $message');

  final Dio _dio = Dio(
    BaseOptions(
      connectTimeout: const Duration(seconds: 15),
      receiveTimeout: const Duration(seconds: 30),
      followRedirects: true,
    ),
  );

  /// 把相对 URL（或完整 URL）解析为绝对 URL，base 默认站点首页。
  String _resolveUrl(String idOrUrl, [String? base]) {
    if (idOrUrl.startsWith('http://') || idOrUrl.startsWith('https://')) {
      return idOrUrl;
    }
    return Uri.parse(base ?? site.url).resolve(idOrUrl).toString();
  }

  /// 应用 urlRewrites（封面/章节图主机被防盗链或地理拦截时换可达主机）。
  String _rewriteUrl(String url) {
    final rw = site.urlRewrites;
    if (rw == null || rw.isEmpty || url.isEmpty) return url;
    var r = url;
    for (final entry in rw.entries) {
      r = r.replaceAll(entry.key, entry.value);
    }
    return r;
  }

  Future<String> _fetchHtml(String url) async {
    // Cloudflare 防护站（Dio 被拦）：走 WebView 抓渲染后 HTML，搜索/分类/详情/章节统一经此。
    if (site.useWebViewFetch) {
      return WebViewImageFetcher().fetchHtml(url);
    }
    final resp = await _dio.get<List<int>>(
      url,
      options: Options(
        headers: {...imageHeaders, 'Referer': site.url},
        responseType: ResponseType.bytes,
      ),
    );
    final bytes = resp.data ?? const <int>[];
    final enc = (site.pageEncoding ?? 'utf-8').toLowerCase();
    if (enc == 'gb2312' || enc == 'gbk') {
      return gbk_bytes.decode(bytes);
    }
    return utf8.decode(bytes, allowMalformed: true);
  }

  @override
  Future<MangasPage> search(
    String query, {
    int page = 0,
    FilterList filters = const FilterList(),
  }) async {
    final tpl = site.searchUrl;
    if (tpl == null || tpl.isEmpty) {
      throw UnsupportedSearchError('源「${site.name}」暂不支持搜索');
    }
    final enc = (site.searchEncoding ?? 'utf-8').toLowerCase();
    String q;
    if (enc == 'gb2312' || enc == 'gbk') {
      // Empire CMS 等站搜索关键词需 gb2312 编码后 percent-encode
      final sb = StringBuffer();
      for (final b in gbk_bytes.encode(query)) {
        sb.write('%');
        sb.write(b.toRadixString(16).padLeft(2, '0'));
      }
      q = sb.toString();
    } else {
      q = Uri.encodeQueryComponent(query);
    }
    var url = tpl
        .replaceAll('{q}', q)
        .replaceAll('{page}', (page + 1).toString());
    if (!url.startsWith('http')) url = _resolveUrl(url);
    final html = await _fetchHtml(url);
    final doc = parse(html);
    final items = <CManga>[];
    final resultDom = site.searchResultDom;
    if (resultDom != null && resultDom.isNotEmpty) {
      for (final r in doc.querySelectorAll(resultDom)) {
        var title = _elText(r, site.searchTitleDom);
        final href = _elAttr(r, site.searchMangaUrlDom, 'href') ?? '';
        if (title.isEmpty && href.isEmpty) continue;
        // 标题空时兜底用封面 img 的 alt（mycomic 卡标题仅在 alt）
        if (title.isEmpty &&
            site.searchCoverDom != null &&
            site.searchCoverDom!.isNotEmpty) {
          title = _elAttr(r, site.searchCoverDom, 'alt') ?? '';
        }
        String cover = '';
        if (site.searchCoverDom != null && site.searchCoverDom!.isNotEmpty) {
          cover = _imgUrl(r.querySelector(site.searchCoverDom!)) ?? '';
        }
        // 归一化：相对路径(/logo/x.jpg)或协议相对(//host/x)封面按当前页 URL 解析为绝对
        if (cover.isNotEmpty && !cover.startsWith('http')) {
          cover = _resolveUrl(cover, url);
        }
        if (cover.isNotEmpty) {
          cover = _rewriteUrl(cover);
        }
        items.add(
          CManga(
            id: href,
            sourceId: id,
            title: title,
            cover: cover,
            url: href.isEmpty ? '' : _resolveUrl(href),
          ),
        );
      }
    }
    // 分页（{page} 占位 + hasNextPage 判断）2b 逐站补
    if (items.isNotEmpty) {
      _log('搜索 ${items.length} 条, 首封面: ${items.first.cover}');
    }
    return MangasPage(items: items, hasNextPage: false);
  }

  @override
  Future<MangasPage> getPopular({int page = 0}) async =>
      const MangasPage(items: [], hasNextPage: false);

  @override
  Future<MangasPage> getLatestUpdates({int page = 0}) async =>
      const MangasPage(items: [], hasNextPage: false);

  @override
  bool get supportsCategories =>
      site.categories != null && site.categories!.isNotEmpty;

  @override
  Future<List<FilterGroup>> fetchCategories() async {
    final cats = site.categories;
    if (cats == null || cats.isEmpty) return const [];
    return [
      FilterGroup(
        key: 'theme',
        title: '题材',
        options: cats,
        selected: cats.first,
      ),
    ];
  }

  @override
  Future<MangasPage> getCategoryList(
    List<FilterGroup> groups, {
    int page = 0,
  }) async {
    final cats = site.categories;
    if (cats == null || cats.isEmpty) {
      return const MangasPage(items: [], hasNextPage: false);
    }
    // 提取 theme slug（selected 或默认第一个）
    FilterGroup? themeGroup;
    for (final g in groups) {
      if (g.key == 'theme') {
        themeGroup = g;
        break;
      }
    }
    final slug = themeGroup?.selected?.value ?? cats.first.value;

    // 拼 URL：page==0 用 categoryUrl，page>=1 用 categoryPageUrl（{page} 1-based）
    final urlTpl = page == 0 ? site.categoryUrl : site.categoryPageUrl;
    if (urlTpl == null) {
      return const MangasPage(items: [], hasNextPage: false);
    }
    var url = urlTpl
        .replaceAll('{slug}', slug)
        .replaceAll('{page}', (page + site.categoryPageStart).toString());
    if (!url.startsWith('http')) url = _resolveUrl(url);

    final html = await _fetchHtml(url);
    final doc = parse(html);
    final items = <CManga>[];
    final listDom = site.categoryListDom;
    if (listDom != null && listDom.isNotEmpty) {
      for (final r in doc.querySelectorAll(listDom)) {
        final href = _elAttr(r, site.categoryUrlDom, 'href') ?? '';
        if (href.isEmpty) continue;
        String cover = '';
        if (site.categoryCoverDom != null &&
            site.categoryCoverDom!.isNotEmpty) {
          cover = _imgUrl(r.querySelector(site.categoryCoverDom!)) ?? '';
        }
        // 归一化：相对路径(/logo/x.jpg)或协议相对(//host/x)封面按当前页 URL 解析为绝对
        if (cover.isNotEmpty && !cover.startsWith('http')) {
          cover = _resolveUrl(cover, url);
        }
        if (cover.isNotEmpty) {
          cover = _rewriteUrl(cover);
        }
        var title = _elText(r, site.categoryTitleDom);
        if (title.isEmpty) {
          // 兜底用 img alt
          title = _elAttr(r, site.categoryCoverDom, 'alt') ?? '';
        }
        items.add(
          CManga(
            id: href,
            sourceId: id,
            title: title,
            cover: cover,
            url: href.isEmpty ? '' : _resolveUrl(href),
          ),
        );
      }
    }

    // hasNextPage：链接式（来漫画）查下一页链接；计数式（mycomic 等 &page=N 站）满页即有下一页
    var hasNext = false;
    final nextDom = site.categoryNextPageDom;
    if (nextDom != null && nextDom.isNotEmpty) {
      final nextHref = doc.querySelector(nextDom)?.attributes['href'];
      hasNext =
          nextHref != null &&
          nextHref.isNotEmpty &&
          nextHref != '#' &&
          !nextHref.toLowerCase().startsWith('javascript');
    } else if (site.categoryPageSize > 0) {
      hasNext = items.length >= site.categoryPageSize;
    }
    _log(
      '分类[$slug] page=$page: ${items.length} 条, hasNext=$hasNext'
      '${items.isNotEmpty ? ", 首封面: ${items.first.cover}" : ""}',
    );
    return MangasPage(items: items, hasNextPage: hasNext);
  }

  @override
  Future<({CManga manga, List<CChapter> chapters})> getMangaDetailsAndChapters(
    CManga manga,
  ) async {
    final detailUrl = _resolveUrl(manga.id);
    final html = await _fetchHtml(detailUrl);
    final doc = parse(html);

    String title = manga.title;
    if (site.comicNameDom.isNotEmpty) {
      final el = doc.querySelector(site.comicNameDom);
      if (el != null && el.text.trim().isNotEmpty) title = el.text.trim();
    }
    String cover = manga.cover;
    if (site.comicCoverDom.isNotEmpty) {
      final el = doc.querySelector(site.comicCoverDom);
      if (el != null) {
        cover = _imgUrl(el) ?? cover;
      }
    }
    final coverRaw = cover;
    if (cover.isNotEmpty) {
      cover = _rewriteUrl(cover);
    }
    _log('详情封面: $coverRaw -> $cover');
    String? author = manga.author;
    if (site.comicAuthorDom.isNotEmpty) {
      final label = site.authorLabel;
      if (label != null && label.isNotEmpty) {
        // 标签式：找含 label 的元素，取去 label+冒号 后的剩余文本（来漫画 .info p.w260）
        for (final el in doc.querySelectorAll(site.comicAuthorDom)) {
          final txt = el.text.trim();
          if (txt.contains(label)) {
            final rest = txt
                .replaceFirst(label, '')
                .replaceFirst(RegExp(r'^[：:\s]+'), '')
                .trim();
            if (rest.isNotEmpty) {
              author = rest;
              break;
            }
          }
        }
      } else {
        final parts = <String>[];
        for (final el in doc.querySelectorAll(site.comicAuthorDom)) {
          var t = el.text.trim();
          // 排除嵌套的「作家信息」等噪声链接文本
          t = t.replaceAll('作家信息', '').replaceAll('详情', '').trim();
          if (t.isNotEmpty) parts.add(t);
        }
        if (parts.isNotEmpty) author = parts.join(', ');
      }
    }
    String? description = manga.description;
    if (site.comicDescDom.isNotEmpty) {
      final el = doc.querySelector(site.comicDescDom);
      if (el != null) {
        final c = el.attributes['content']?.trim();
        final t = el.text.trim();
        if (c != null && c.isNotEmpty) {
          description = c;
        } else if (t.isNotEmpty) {
          description = t;
        }
      }
    }

    // 章节列表
    final chapters = <CChapter>[];
    final seen = <String>{};
    if (site.chapterScript.isNotEmpty) {
      // chapterScript 模式：SSR 无章节（骨架屏），3 阶段直连取章节
      // 阶段1 详情页 chapterScript 返回 {apiUrl,linkBase}；阶段2 loadRequest(apiUrl) 直连
      // 取 JSON（浏览器绕 CORS/TLS 拦截，如 godamh v2.apikk.top）；阶段3 chapterJsonScript 映射
      final list = await WebViewImageFetcher().fetchChapters(
        detailUrl,
        site.chapterScript,
        site.chapterJsonScript,
      );
      var order = 0;
      for (final c in list) {
        final chapterUrl = _resolveUrl(c['url'] ?? '', detailUrl);
        if (chapterUrl.isEmpty || !seen.add(chapterUrl)) continue;
        chapters.add(
          CChapter(
            id: chapterUrl,
            sourceId: id,
            mangaId: manga.id,
            name: c['name'] ?? '',
            url: chapterUrl,
            order: order++,
          ),
        );
      }
    } else {
      var order = _parseChapters(doc, detailUrl, manga, chapters, seen, 0);
      if (site.chapterPageCountDom.isNotEmpty &&
          site.chapterPagedUrl.isNotEmpty) {
        final base = _pagedBaseUrl(doc, detailUrl);
        final pageCount = _maxPage(doc, site.chapterPageCountDom);
        _log('章节分页: base=$base, 总页数=$pageCount');
        for (var p = 2; p <= pageCount; p++) {
          final pageUrl = site.chapterPagedUrl
              .replaceAll('{base}', base)
              .replaceAll('{page}', p.toString());
          try {
            final before = chapters.length;
            order = _parseChapters(
              parse(await _fetchHtml(pageUrl)),
              pageUrl,
              manga,
              chapters,
              seen,
              order,
            );
            if (chapters.length == before) {
              _log('分页第 $p 页无新增，停止');
              break; // 超页返回最后一页，无新增即终止
            }
          } catch (e) {
            _log('分页第 $p 页失败: $e');
            break;
          }
        }
      }
    }
    // chapterOrder: 0=倒序 1=正序（DOM 顺序按站点实际，按配置调整）
    if (site.chapterOrder == 0) {
      chapters.sort((a, b) => b.order.compareTo(a.order));
    }
    _log('详情+章节: $detailUrl, 章节数 ${chapters.length}');
    return (
      manga: manga.copyWith(
        title: title,
        cover: cover,
        author: author,
        description: description,
        url: detailUrl,
        initialized: true,
      ),
      chapters: chapters,
    );
  }

  /// 解析一页章节列表，追加到 chapters（seen 去重），返回更新后的 order。
  int _parseChapters(
    Document doc,
    String pageUrl,
    CManga manga,
    List<CChapter> chapters,
    Set<String> seen,
    int order,
  ) {
    if (site.chapterLinkDom.isEmpty) return order;
    for (final a in doc.querySelectorAll(site.chapterLinkDom)) {
      final href = a.attributes['href'] ?? '';
      if (href.isEmpty || href.startsWith('javascript:')) continue;
      // 章节链接 href 模式过滤（空=不过滤；mycomic 详情页 .mt-8.mb-12 区混有推荐等非章节链接）
      if (site.chapterUrlPattern.isNotEmpty &&
          !href.contains(site.chapterUrlPattern)) {
        continue;
      }
      final chapterUrl = _resolveUrl(href, pageUrl);
      if (!seen.add(chapterUrl)) continue; // 跨页去重
      String name = a.text.trim();
      if (name.isEmpty && site.chapterNameDom.isNotEmpty) {
        final ne = a.querySelector(site.chapterNameDom);
        if (ne != null) name = ne.text.trim();
      }
      chapters.add(
        CChapter(
          id: chapterUrl,
          sourceId: id,
          mangaId: manga.id,
          name: name,
          url: chapterUrl,
          order: order++,
        ),
      );
    }
    return order;
  }

  /// 分页基础 URL：优先 chapterPagedBaseDom（meta content），否则用详情页 URL；去掉已有 page 参数。
  String _pagedBaseUrl(Document doc, String detailUrl) {
    String base = detailUrl;
    if (site.chapterPagedBaseDom.isNotEmpty) {
      final el = doc.querySelector(site.chapterPagedBaseDom);
      final c = el?.attributes['content'];
      if (c != null && c.isNotEmpty) base = c;
    }
    return base.replaceFirst(RegExp(r'[?&]page=\d+'), '');
  }

  /// 从分页容器内取最大页码数字。
  int _maxPage(Document doc, String selector) {
    final el = doc.querySelector(selector);
    if (el == null) return 1;
    var max = 1;
    for (final m in RegExp(r'\d+').allMatches(el.text)) {
      final n = int.tryParse(m.group(0)!) ?? 0;
      if (n > max) max = n;
    }
    return max;
  }

  @override
  Future<CManga> getMangaDetails(CManga manga) async =>
      (await getMangaDetailsAndChapters(manga)).manga;

  @override
  Future<List<CChapter>> getChapterList(CManga manga) async =>
      (await getMangaDetailsAndChapters(manga)).chapters;

  @override
  Future<List<String>> getChapterImages(CManga manga, CChapter chapter) async {
    final url = chapter.url ?? _resolveUrl(chapter.id);
    if (site.useFrame == 0) {
      return _directImages(url);
    }
    final imgs = await WebViewImageFetcher().fetch(url, site);
    return site.urlRewrites == null || site.urlRewrites!.isEmpty
        ? imgs
        : imgs.map(_rewriteUrl).toList();
  }

  /// 直连取图：Dio 章节页 HTML + imgDom/imgAttr 提取。
  Future<List<String>> _directImages(String chapterUrl) async {
    final html = await _fetchHtml(chapterUrl);
    final doc = parse(html);
    if (site.imgDom.isEmpty) return [];
    final urls = <String>[];
    for (final img in doc.querySelectorAll(site.imgDom)) {
      final u = site.imgAttr.isNotEmpty
          ? (img.attributes[site.imgAttr] ?? '')
          : (img.attributes['src'] ?? '');
      if (u.isNotEmpty && u.indexOf('data:') != 0) {
        urls.add(_resolveUrl(u, chapterUrl));
      }
    }
    _log('直连取图: $chapterUrl, ${urls.length} 张');
    // TODO(2b): imgLoadMode=3 直连翻页合并
    return urls;
  }

  String _elText(Element el, String? selector) {
    if (selector == null || selector.isEmpty) return '';
    return el.querySelector(selector)?.text.trim() ?? '';
  }

  String? _elAttr(Element el, String? selector, String attr) {
    if (selector == null || selector.isEmpty) return null;
    return el.querySelector(selector)?.attributes[attr];
  }

  /// 取图片真实 URL：依次试 src/data-src/data-original/data-lazy-src/data-url，
  /// 跳过空值与 data: 占位（懒加载站 src 初始常为 1x1 透明占位，非空但不可用，
  /// 故 ?? 链无效，必须显式跳过 data: 才能落到 data-src 等真实属性）。
  String? _imgUrl(Element? img) {
    if (img == null) return null;
    for (final attr in const [
      'src',
      'data-src',
      'data-original',
      'data-lazy-src',
      'data-url',
    ]) {
      final v = img.attributes[attr];
      if (v != null && v.isNotEmpty && !v.startsWith('data:')) return v;
    }
    return img.attributes['src']; // 全占位/空时回退 src，保留原行为兜底
  }
}
