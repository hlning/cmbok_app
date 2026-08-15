// 配置驱动的漫画站点模型（对齐桌面端 comic_website 表字段 + app 搜索扩展）。
//
// 桌面端 default_sites（common/sqlite_util.py）定义 14 站取图配置，app 端迁移其中 11 站
// （排除「拷贝漫画 copy3000」-- CopyMangaSource 走 API；「咚漫」-- PC 章节不全；
//  「再漫画」-- API 驱动 SPA，由 ZaimanhuaSource 接管）。
// 桌面端无搜索字段，searchUrl 等为 app 新增，2b 逐站补。
//
// 内置站点数据已迁至 assets/config/sources.json（出厂默认）+ 文档目录 sources.json
// （远端更新覆盖层），代码侧只保留本模型（字段/fromJson/toJson），不再硬编码站点。

import 'models.dart';

/// 单个漫画站点配置
class SiteConfig {
  final String name;
  final String? icon;
  final String url;

  // 详情页 DOM 选择器
  final String comicCoverDom;
  final String comicNameDom;
  final String comicAuthorDom;
  final String comicDescDom; // 简介（meta[property=...] 取 content，或普通元素取 text）

  // 章节列表 DOM 选择器
  final String chapterNameDom;
  final String chapterLinkDom;
  // 章节链接 href 必须包含的片段（空=不过滤；如 mycomic 用 /cn/chapters/ 排除推荐等非章节链接）
  final String chapterUrlPattern;
  // 章节兜底链接选择器（单行本场景：无章节列表，只有「开始阅读」按钮时取其 href 作为唯一章节）
  final String chapterFallbackLinkDom;
  // 章节分页（PC 网页分页，空=不分页）
  final String chapterPagedUrl; // 模板 {base}&page={page}（{base}=基础URL，{page}=页码）
  final String
  chapterPagedBaseDom; // 基础URL选择器（如 meta[property="og:url"] 取 content）；空=用详情页URL
  final String chapterPageCountDom; // 总页数容器选择器（取内最大数字）；空=不分页

  // 取图配置
  final String imgDom;
  final int useFrame; // 0=直连(Dio+html) 1=iframe(WebView 注入)
  final String imgAttr; // 图片属性名（空=src）
  final String imgScript; // 取图 JS 片段（iframe 模式，桌面端用 ifr.contentWindow）
  final String
  chapterScript; // 章节列表 JS（详情页 WebView 内执行返回 {apiUrl,linkBase}；空=Dio 解析 chapterLinkDom）
  final String
  chapterJsonScript; // 章节 JSON 解析 JS（注入 json+linkBase 执行返回 [{name,url}]；配合 chapterScript 的 apiUrl）
  final String imgReferer; // 图片 Referer（空=site.url，'none'=不发，其他=自定义值）
  final int imgLoadMode; // 1=滚动 2=滚到底 3=下一页
  final String nextPageSelector; // 下一页选择器（imgLoadMode=3）
  final String pageLabelSelector;

  final int chapterOrder; // 0=倒序 1=正序
  final bool chapterSortByOrder; // true=按 order(DOM顺序)排，跳过智能排序（更新时间序站点用）
  final int crossOrigin; // 0=同源 1=跨源
  final String restoreAlgorithm; // 图片还原算法名（如「腐漫」）
  final bool useBlobBase64; // blob 站走 base64 取图（如摸摸漫画），其余 blob 站用还原后真实 URL
  final String imgAesKey; // 章节图 AES-CBC 密钥（utf-8 前 32 字节；密文=前 16 字节 IV+密文）。
  // 非空时 Dio 直下密文本地解密落盘，不走 WebView 逐张解密（如漫蛙）
  final String imgUrlPattern; // 章节图 URL 模板（{comicId}/{chapterNo}/{index} 占位）。
  // 非空时跳过 WebView，按序号直下到 404 为止（如摸摸 c2.2thewash.com）
  final String imgUrlIdRegex; // 从章节 URL 提取 comicId/chapterNo 的正则（两组捕获）
  final bool imgBodyBase64; // 章节图响应体是图片的 base64 文本（摸摸），下载后解码落盘
  final String
  coverUrlPattern; // 封面直连 URL 模板（{comicId} 占位，如摸摸 cover.2thewash.com）。
  // 非空时列表/详情封面一律按模板生成（渲染 DOM 里的 blob/_ipx 地址不可直连）
  final String
  coverIdRegex; // 从漫画 URL 提取 comicId 的正则（一组捕获，配 coverUrlPattern 用）

  // app 搜索扩展（可空，2b 逐站补）
  final String? searchUrl; // 搜索 URL 模板，{q} 占位
  final String? searchResultDom; // 搜索结果项选择器
  final String? searchTitleDom;
  final String? searchCoverDom;
  final String? searchMangaUrlDom; // 详情页相对 URL 选择器
  final String? searchEncoding; // 搜索关键词编码（默认 utf-8；Empire CMS 站=gb2312）
  final String? authorLabel; // 作者标签文本（详情页作者区「原著作者」等，取去 label 后剩余文本）
  final String? pageEncoding; // 页面响应编码（默认 utf-8；来漫画等 Empire CMS 站=gb2312）
  final bool
  useWebViewFetch; // true=搜索/分类/详情/章节走 WebView 抓 HTML（Cloudflare 防护站，Dio 被拦）

  // app 分类扩展（可空，2b 逐站补）
  // 新版：categories 是 Map<String, _CatGroup>，key 即 FilterGroup.key / URL 占位符名
  //   例："categories": {
  //     "theme":  { "title": "题材", "options": [{"value":"all","name":"全部"}, ...] },
  //     "status": { "title": "进度", "options": [...] },
  //     "sort":   { "title": "排序", "options": [...] }
  //   }
  //   URL 用 {theme}/{status}/{sort} 占位，显示顺序按 map 插入顺序
  // 旧版（兼容）：categories 是 List<FilterOption>，等价于 {"theme": {title:"题材", options:[...]}}
  final List<FilterOption>? categories; // 旧版兼容：等价于 theme 组
  final Map<String, List<FilterOption>>? categoryGroups; // 新版：多维度分组（内部归一化用）
  final Map<String, String>? categoryGroupTitles; // 新版：分组显示标题（key->title）
  final String? categoryUrl; // 分类第1页 URL 模板（{key名} 占位 + {page}）
  final String? categoryPageUrl; // 分类后续页 URL 模板（{key名} 占位 + {page}）
  final String? categoryListDom; // 分类列表项选择器
  final String? categoryCoverDom; // 分类项封面 img 选择器
  final String? categoryTitleDom; // 分类项标题选择器
  final String? categoryUrlDom; // 分类项详情链接选择器（取 href）
  final String? categoryNextPageDom; // 下一页链接选择器（hasNextPage 判断）
  final int categoryPageSize; // 计数式分页每页条数（>0 时满页即有下一页；来漫画用链接式留 0）
  final int
  categoryPageStart; // 分页页码起始偏移（{page}=page+此值；默认1，lmanhua pageN.html=第N+1页用0）
  final Map<String, String>?
  urlRewrites; // 图片 URL 子串替换（封面/章节图主机被防盗链或地理拦截时换可达主机，如 static-tw->cn）

  /// 归一化分类分组：新版 categoryGroups（Map）优先，旧版 categories（List）
  /// 退化为 {"theme": categories}。
  Map<String, List<FilterOption>> get normalizedCategoryGroups {
    if (categoryGroups != null && categoryGroups!.isNotEmpty) {
      return categoryGroups!;
    }
    if (categories != null && categories!.isNotEmpty) {
      return {'theme': categories!};
    }
    return const {};
  }

  /// 归一化分组标题：新版 categoryGroupTitles 优先，旧版退化为 {"theme": "题材"}。
  String categoryGroupTitle(String key) {
    if (categoryGroupTitles != null && categoryGroupTitles!.containsKey(key)) {
      return categoryGroupTitles![key]!;
    }
    if (key == 'theme') return '题材';
    return key;
  }

  const SiteConfig({
    required this.name,
    this.icon,
    required this.url,
    this.comicCoverDom = '',
    this.comicNameDom = '',
    this.comicAuthorDom = '',
    this.comicDescDom = '',
    this.chapterNameDom = '',
    this.chapterLinkDom = '',
    this.chapterUrlPattern = '',
    this.chapterFallbackLinkDom = '',
    this.chapterPagedUrl = '',
    this.chapterPagedBaseDom = '',
    this.chapterPageCountDom = '',
    this.imgDom = '',
    this.useFrame = 1,
    this.imgAttr = '',
    this.imgScript = '',
    this.chapterScript = '',
    this.chapterJsonScript = '',
    this.imgReferer = '',
    this.imgLoadMode = 1,
    this.nextPageSelector = '',
    this.pageLabelSelector = '',
    this.chapterOrder = 1,
    this.chapterSortByOrder = false,
    this.crossOrigin = 0,
    this.restoreAlgorithm = '',
    this.useBlobBase64 = false,
    this.imgAesKey = '',
    this.imgUrlPattern = '',
    this.imgUrlIdRegex = r'comics/(\d+)/(\d+)',
    this.imgBodyBase64 = false,
    this.coverUrlPattern = '',
    this.coverIdRegex = r'comics/(\d+)',
    this.searchUrl,
    this.searchResultDom,
    this.searchTitleDom,
    this.searchCoverDom,
    this.searchMangaUrlDom,
    this.searchEncoding,
    this.authorLabel,
    this.pageEncoding,
    this.useWebViewFetch = false,
    this.categories,
    this.categoryGroups,
    this.categoryGroupTitles,
    this.categoryUrl,
    this.categoryPageUrl,
    this.categoryListDom,
    this.categoryCoverDom,
    this.categoryTitleDom,
    this.categoryUrlDom,
    this.categoryNextPageDom,
    this.categoryPageSize = 0,
    this.categoryPageStart = 1,
    this.urlRewrites,
  });

  factory SiteConfig.fromJson(Map<String, dynamic> j) => SiteConfig(
    name: j['name'] as String,
    icon: j['icon'] as String?,
    url: j['url'] as String,
    comicCoverDom: (j['comic_cover_dom'] as String?) ?? '',
    comicNameDom: (j['comic_name_dom'] as String?) ?? '',
    comicAuthorDom: (j['comic_author_dom'] as String?) ?? '',
    comicDescDom: (j['comic_desc_dom'] as String?) ?? '',
    chapterNameDom: (j['chapter_name_dom'] as String?) ?? '',
    chapterLinkDom: (j['chapter_link_dom'] as String?) ?? '',
    chapterUrlPattern: (j['chapter_url_pattern'] as String?) ?? '',
    chapterFallbackLinkDom: (j['chapter_fallback_link_dom'] as String?) ?? '',
    chapterPagedUrl: (j['chapter_paged_url'] as String?) ?? '',
    chapterPagedBaseDom: (j['chapter_paged_base_dom'] as String?) ?? '',
    chapterPageCountDom: (j['chapter_page_count_dom'] as String?) ?? '',
    imgDom: (j['img_dom'] as String?) ?? '',
    useFrame: (j['use_frame'] as num?)?.toInt() ?? 1,
    imgAttr: (j['img_attr'] as String?) ?? '',
    imgScript: (j['img_script'] as String?) ?? '',
    chapterScript: (j['chapter_script'] as String?) ?? '',
    chapterJsonScript: (j['chapter_json_script'] as String?) ?? '',
    imgReferer: (j['img_referer'] as String?) ?? '',
    imgLoadMode: (j['img_load_mode'] as num?)?.toInt() ?? 1,
    nextPageSelector: (j['next_page_selector'] as String?) ?? '',
    pageLabelSelector: (j['page_label_selector'] as String?) ?? '',
    chapterOrder: (j['chapter_order'] as num?)?.toInt() ?? 1,
    chapterSortByOrder: (j['chapter_sort_by_order'] as bool?) ?? false,
    crossOrigin: (j['cross_origin'] as num?)?.toInt() ?? 0,
    restoreAlgorithm: (j['restore_algorithm'] as String?) ?? '',
    useBlobBase64: (j['use_blob_base64'] as bool?) ?? false,
    imgAesKey: (j['img_aes_key'] as String?) ?? '',
    imgUrlPattern: (j['img_url_pattern'] as String?) ?? '',
    imgUrlIdRegex: (j['img_url_id_regex'] as String?) ?? r'comics/(\d+)/(\d+)',
    imgBodyBase64: (j['img_body_base64'] as bool?) ?? false,
    coverUrlPattern: (j['cover_url_pattern'] as String?) ?? '',
    coverIdRegex: (j['cover_id_regex'] as String?) ?? r'comics/(\d+)',
    searchUrl: j['search_url'] as String?,
    searchResultDom: j['search_result_dom'] as String?,
    searchTitleDom: j['search_title_dom'] as String?,
    searchCoverDom: j['search_cover_dom'] as String?,
    searchMangaUrlDom: j['search_manga_url_dom'] as String?,
    searchEncoding: j['search_encoding'] as String?,
    authorLabel: j['author_label'] as String?,
    pageEncoding: j['page_encoding'] as String?,
    useWebViewFetch: (j['use_webview_fetch'] as bool?) ?? false,
    categories: (j['categories'] is List)
        ? (j['categories'] as List)
              .map(
                (e) => FilterOption(
                  value: e['value'] as String,
                  name: e['name'] as String,
                  isAll: (e['isAll'] as bool?) ?? false,
                ),
              )
              .toList()
        : null,
    categoryGroups: (j['categories'] is Map)
        ? (j['categories'] as Map).map((k, v) {
            final groupMap = v as Map;
            final options = (groupMap['options'] as List)
                .map(
                  (e) => FilterOption(
                    value: e['value'] as String,
                    name: e['name'] as String,
                    isAll: (e['isAll'] as bool?) ?? false,
                  ),
                )
                .toList();
            return MapEntry(k as String, options);
          })
        : null,
    categoryGroupTitles: (j['categories'] is Map)
        ? (j['categories'] as Map).map(
            (k, v) =>
                MapEntry(k as String, ((v as Map)['title'] as String?) ?? k),
          )
        : null,
    categoryUrl: j['category_url'] as String?,
    categoryPageUrl: j['category_page_url'] as String?,
    categoryListDom: j['category_list_dom'] as String?,
    categoryCoverDom: j['category_cover_dom'] as String?,
    categoryTitleDom: j['category_title_dom'] as String?,
    categoryUrlDom: j['category_url_dom'] as String?,
    categoryNextPageDom: j['category_next_page_dom'] as String?,
    categoryPageSize: (j['category_page_size'] as num?)?.toInt() ?? 0,
    categoryPageStart: (j['category_page_start'] as num?)?.toInt() ?? 1,
    urlRewrites: (j['url_rewrites'] as Map?)?.map(
      (k, v) => MapEntry(k.toString(), v.toString()),
    ),
  );

  Map<String, dynamic> toJson() => {
    'name': name,
    'icon': icon,
    'url': url,
    'comic_cover_dom': comicCoverDom,
    'comic_name_dom': comicNameDom,
    'comic_author_dom': comicAuthorDom,
    'comic_desc_dom': comicDescDom,
    'chapter_name_dom': chapterNameDom,
    'chapter_link_dom': chapterLinkDom,
    'chapter_url_pattern': chapterUrlPattern,
    'chapter_fallback_link_dom': chapterFallbackLinkDom,
    'chapter_paged_url': chapterPagedUrl,
    'chapter_paged_base_dom': chapterPagedBaseDom,
    'chapter_page_count_dom': chapterPageCountDom,
    'img_dom': imgDom,
    'use_frame': useFrame,
    'img_attr': imgAttr,
    'img_script': imgScript,
    'chapter_script': chapterScript,
    'chapter_json_script': chapterJsonScript,
    'img_referer': imgReferer,
    'img_load_mode': imgLoadMode,
    'next_page_selector': nextPageSelector,
    'page_label_selector': pageLabelSelector,
    'chapter_order': chapterOrder,
    'chapter_sort_by_order': chapterSortByOrder,
    'cross_origin': crossOrigin,
    'restore_algorithm': restoreAlgorithm,
    'use_blob_base64': useBlobBase64,
    'img_aes_key': imgAesKey,
    'img_url_pattern': imgUrlPattern,
    'img_url_id_regex': imgUrlIdRegex,
    'img_body_base64': imgBodyBase64,
    'cover_url_pattern': coverUrlPattern,
    'cover_id_regex': coverIdRegex,
    'search_url': searchUrl,
    'search_result_dom': searchResultDom,
    'search_title_dom': searchTitleDom,
    'search_cover_dom': searchCoverDom,
    'search_manga_url_dom': searchMangaUrlDom,
    'search_encoding': searchEncoding,
    'author_label': authorLabel,
    'page_encoding': pageEncoding,
    'use_webview_fetch': useWebViewFetch,
    'categories': categoryGroups != null
        ? categoryGroups!.map(
            (k, v) => MapEntry(
              k,
              v
                  .map(
                    (e) => {'value': e.value, 'name': e.name, 'isAll': e.isAll},
                  )
                  .toList(),
            ),
          )
        : categories
              ?.map((e) => {'value': e.value, 'name': e.name, 'isAll': e.isAll})
              .toList(),
    'category_url': categoryUrl,
    'category_page_url': categoryPageUrl,
    'category_list_dom': categoryListDom,
    'category_cover_dom': categoryCoverDom,
    'category_title_dom': categoryTitleDom,
    'category_url_dom': categoryUrlDom,
    'category_next_page_dom': categoryNextPageDom,
    'category_page_size': categoryPageSize,
    'category_page_start': categoryPageStart,
    if (urlRewrites != null) 'url_rewrites': urlRewrites,
  };
}
