// 漫画人源（动漫屋 dm5 系 .ashx + Dean-Edwards packer 取图）的可变配置。
//
// 漫画人属动漫屋系，接口形态：搜索=search.ashx（裸 JSON 数组）、分类页1=HTML /
// 页2+=POST dm5.ashx?action=getclasscomics（JSON）、详情+章节=HTML SSR、章节图=
// eval(packer) 解包后 var newImgs=[...]。这些是 dm5 系共享协议，换 host/字段映射
// 即可复用 ManhuarenSource 引擎（如动漫屋 dm5.com、看漫画等同源姊妹站）。
//
// 分类 slug 由站点静态路径决定（/manhua-{slug}/），预定义于 [categories]，
// 不走远端拉取（manhuaren 无分类维度 API，纯路径式）。

import 'models.dart';

/// 合并默认字符串映射与传入覆盖。
Map<String, String> _strMap(dynamic j, Map<String, String> defaults) {
  final m = Map<String, String>.from(defaults);
  if (j is Map) {
    j.forEach((k, v) {
      if (k is String && v != null) m[k] = '$v';
    });
  }
  return m;
}

/// 漫画人源完整配置。
class ManhuarenConfig {
  /// 全局唯一 id（协议标识，对齐 ManhuarenSource.id 与 currentSourceId 持久化）。
  final String id;

  /// 站点首页（搜索/分类/详情/章节/取图 API 的 base）。
  final String base;

  /// 请求 UA。
  final String ua;

  /// 分类主题列表（站点的 /manhua-{slug}/ 路径分类，预定义不走远端）。
  final List<FilterOption> categories;

  /// 分类页每页条数（页1=HTML SSR，页2+=POST JSON；满页即有下一页）。
  final int categoryPageSize;

  final MhSearch search;
  final MhCategory category;
  final MhDetail detail;
  final MhChapterImage chapterImage;

  const ManhuarenConfig({
    required this.id,
    required this.base,
    required this.ua,
    required this.categories,
    required this.categoryPageSize,
    required this.search,
    required this.category,
    required this.detail,
    required this.chapterImage,
  });

  static const _defaultUa =
      'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
      '(KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36';

  factory ManhuarenConfig.fromJson(Map<String, dynamic> j) {
    final cats = (j['categories'] as List?)
        ?.whereType<Map<String, dynamic>>()
        .map(
          (e) => FilterOption(
            value: (e['value'] ?? '').toString(),
            name: (e['name'] ?? '').toString(),
            isAll: (e['isAll'] as bool?) ?? false,
          ),
        )
        .toList();
    return ManhuarenConfig(
      id: (j['id'] as String?) ?? 'manhuaren',
      base: (j['base'] as String?) ?? 'https://www.manhuaren.com/',
      ua: (j['ua'] as String?) ?? _defaultUa,
      categories: cats ?? _defaultCategories,
      categoryPageSize: (j['categoryPageSize'] as num?)?.toInt() ?? 10,
      search: MhSearch.fromJson(j['search'] as Map<String, dynamic>?),
      category: MhCategory.fromJson(j['category'] as Map<String, dynamic>?),
      detail: MhDetail.fromJson(j['detail'] as Map<String, dynamic>?),
      chapterImage: MhChapterImage.fromJson(
        j['chapterImage'] as Map<String, dynamic>?,
      ),
    );
  }

  /// 站点搜索页列出的 25 个热门分类主题（slug 古怪拼音）。
  static const _defaultCategories = [
    FilterOption(value: 'rexue', name: '热血'),
    FilterOption(value: 'aiqing', name: '恋爱'),
    FilterOption(value: 'xiaoyuan', name: '校园'),
    FilterOption(value: 'weiniang', name: '伪娘'),
    FilterOption(value: 'maoxian', name: '冒险'),
    FilterOption(value: 'zhichang', name: '职场'),
    FilterOption(value: 'hougong', name: '后宫'),
    FilterOption(value: 'zhiyu', name: '治愈'),
    FilterOption(value: 'kehuan', name: '科幻'),
    FilterOption(value: 'qingxiaoshuo1', name: '轻小说'),
    FilterOption(value: 'lizhi', name: '励志'),
    FilterOption(value: 'shenghuoqinqing', name: '生活'),
    FilterOption(value: 'zhanzheng', name: '战争'),
    FilterOption(value: 'xuanyi', name: '悬疑'),
    FilterOption(value: 'zhentan', name: '推理'),
    FilterOption(value: 'gaoxiao', name: '搞笑'),
    FilterOption(value: 'qihuan', name: '奇幻'),
    FilterOption(value: 'mofa', name: '魔法'),
    FilterOption(value: 'dongfangshengui', name: '神鬼'),
    FilterOption(value: 'mengxi', name: '萌系'),
    FilterOption(value: 'lishi', name: '历史'),
    FilterOption(value: 'meishi', name: '美食'),
    FilterOption(value: 'tongren', name: '同人'),
    FilterOption(value: 'jingji', name: '运动'),
    FilterOption(value: 'jizhan', name: '机甲'),
  ];

  Map<String, dynamic> toJson() => {
    'id': id,
    'base': base,
    'ua': ua,
    'categories': categories
        .map((e) => {'value': e.value, 'name': e.name, 'isAll': e.isAll})
        .toList(),
    'categoryPageSize': categoryPageSize,
    'search': search.toJson(),
    'category': category.toJson(),
    'detail': detail.toJson(),
    'chapterImage': chapterImage.toJson(),
  };
}

/// 搜索接口配置（search.ashx，返回裸 JSON 数组）。
class MhSearch {
  /// 相对 base 的路径（含 .ashx）。
  final String path;

  /// 关键词参数名。
  final String queryKey;

  /// 语言参数（manhuaren 站固定传 1=中文）。
  final String languageKey;
  final String languageValue;

  /// 是否去 HTML（manhuaren 站固定传 1）。
  final String removeHtmlKey;
  final String removeHtmlValue;

  /// 结果项字段映射：id/title/url/lastPartUrl/cover。
  /// 注：search.ashx 不返回 cover，cover 为空字符串（详情页补全）。
  final Map<String, String> fields;

  const MhSearch({
    required this.path,
    required this.queryKey,
    required this.languageKey,
    required this.languageValue,
    required this.removeHtmlKey,
    required this.removeHtmlValue,
    required this.fields,
  });

  factory MhSearch.fromJson(Map<String, dynamic>? j) => MhSearch(
    path: (j?['path'] as String?) ?? 'search.ashx',
    queryKey: (j?['queryKey'] as String?) ?? 't',
    languageKey: (j?['languageKey'] as String?) ?? 'language',
    languageValue: (j?['languageValue'] as String?) ?? '1',
    removeHtmlKey: (j?['removeHtmlKey'] as String?) ?? 'isremovehtml',
    removeHtmlValue: (j?['removeHtmlValue'] as String?) ?? '1',
    fields: _strMap(j?['fields'], const {
      'id': 'ID',
      'title': 'Title',
      'url': 'Url',
      'lastPartUrl': 'LastPartUrl',
      'lastPartName': 'LastPartName',
    }),
  );

  Map<String, dynamic> toJson() => {
    'path': path,
    'queryKey': queryKey,
    'languageKey': languageKey,
    'languageValue': languageValue,
    'removeHtmlKey': removeHtmlKey,
    'removeHtmlValue': removeHtmlValue,
    'fields': fields,
  };
}

/// 分类页配置（页1 HTML SSR，页2+ POST JSON dm5.ashx）。
class MhCategory {
  /// 第1页 URL 模板（{slug} 占位，相对 base）。
  final String firstPagePath;

  /// 第2+ 页 JSON 接口路径（相对 base）。
  final String nextPagePath;

  /// 第2+ 页 action 参数值。
  final String action;

  /// 页码参数名（pageindex，1-based；第1页 HTML 也用此页码）。
  final String pageKey;

  /// 每页条数参数名。
  final String sizeKey;

  /// 指定分类的 tagid 参数名（页2+ JSON 必传；slug→tagid 映射见 [slugToTagId]）。
  final String tagIdKey;

  /// 其它固定参数（status/usergroup/pay/areaid/sort/iscopyright，manhuaren 站的全=0 默认）。
  final Map<String, String> fixedParams;

  /// JSON 结果列表字段。
  final String listField;

  /// JSON 结果项字段映射：id/title/url/cover/lastPartUrl/lastPartName/status。
  final Map<String, String> itemFields;

  /// HTML 第1页列表项选择器与子选择器。
  final String htmlListItemDom;
  final String htmlCoverDom;
  final String htmlTitleDom;
  final String htmlUrlDom;

  /// slug→tagid 映射（用于页2+ JSON 的 tagid 参数）。
  /// manhuaren 页1 HTML 内会暴露 tagid 变量，运行时由源解析后填充；
  /// 缺失时回退本表的默认值（已知热门分类）。
  final Map<String, String> slugToTagId;

  const MhCategory({
    required this.firstPagePath,
    required this.nextPagePath,
    required this.action,
    required this.pageKey,
    required this.sizeKey,
    required this.tagIdKey,
    required this.fixedParams,
    required this.listField,
    required this.itemFields,
    required this.htmlListItemDom,
    required this.htmlCoverDom,
    required this.htmlTitleDom,
    required this.htmlUrlDom,
    required this.slugToTagId,
  });

  factory MhCategory.fromJson(Map<String, dynamic>? j) => MhCategory(
    firstPagePath: (j?['firstPagePath'] as String?) ?? '/manhua-{slug}/',
    nextPagePath: (j?['nextPagePath'] as String?) ?? 'dm5.ashx',
    action: (j?['action'] as String?) ?? 'getclasscomics',
    pageKey: (j?['pageKey'] as String?) ?? 'pageindex',
    sizeKey: (j?['sizeKey'] as String?) ?? 'pagesize',
    tagIdKey: (j?['tagIdKey'] as String?) ?? 'tagid',
    fixedParams: _strMap(j?['fixedParams'], const {
      'categoryid': '0',
      'status': '0',
      'usergroup': '0',
      'pay': '-1',
      'areaid': '0',
      'sort': '10',
      'iscopyright': '0',
    }),
    listField: (j?['listField'] as String?) ?? 'UpdateComicItems',
    itemFields: _strMap(j?['itemFields'], const {
      'id': 'ID',
      'title': 'Title',
      'url': 'UrlKey',
      'cover': 'ShowPicUrlB',
      'lastPartUrl': 'LastPartUrl',
      'lastPartName': 'ShowLastPartName',
      'status': 'Status',
    }),
    htmlListItemDom:
        (j?['htmlListItemDom'] as String?) ?? 'ul.manga-list-2 > li',
    htmlCoverDom: (j?['htmlCoverDom'] as String?) ?? '.manga-list-2-cover-img',
    htmlTitleDom: (j?['htmlTitleDom'] as String?) ?? '.manga-list-2-title a',
    htmlUrlDom: (j?['htmlUrlDom'] as String?) ?? '.manga-list-2-title a',
    slugToTagId: _strMap(j?['slugToTagId'], const {
      'rexue': '31',
      'aiqing': '26',
      'xiaoyuan': '1',
      'weiniang': '5',
      'maoxian': '2',
      'zhichang': '6',
      'hougong': '8',
      'zhiyu': '9',
      'kehuan': '25',
      'qingxiaoshuo1': '156',
      'lizhi': '10',
      'shenghuoqinqing': '11',
      'zhanzheng': '12',
      'xuanyi': '17',
      'zhentan': '33',
      'gaoxiao': '37',
      'qihuan': '14',
      'mofa': '15',
      'dongfangshengui': '20',
      'mengxi': '21',
      'lishi': '4',
      'meishi': '7',
      'tongren': '30',
      'jingji': '34',
      'jizhan': '40',
    }),
  );

  Map<String, dynamic> toJson() => {
    'firstPagePath': firstPagePath,
    'nextPagePath': nextPagePath,
    'action': action,
    'pageKey': pageKey,
    'sizeKey': sizeKey,
    'tagIdKey': tagIdKey,
    'fixedParams': fixedParams,
    'listField': listField,
    'itemFields': itemFields,
    'htmlListItemDom': htmlListItemDom,
    'htmlCoverDom': htmlCoverDom,
    'htmlTitleDom': htmlTitleDom,
    'htmlUrlDom': htmlUrlDom,
    'slugToTagId': slugToTagId,
  };
}

/// 详情+章节接口配置（HTML SSR 解析）。
class MhDetail {
  /// 详情页 DOM 选择器。
  final String coverDom;
  final String titleDom;
  final String authorDom;
  final String descDom;
  final String tagDom;

  /// 章节列表 DOM 选择器。
  /// 注：详情页含多个分组（连载/番外），每组一个 ul[id^=detail-list-select-N]。
  /// 此选择器须能命中所有分组内的章节项。
  final String chapterGroupDom;
  final String chapterItemDom;
  final String chapterLinkDom;
  final String chapterNameDom;
  final String chapterDateDom;

  const MhDetail({
    required this.coverDom,
    required this.titleDom,
    required this.authorDom,
    required this.descDom,
    required this.tagDom,
    required this.chapterGroupDom,
    required this.chapterItemDom,
    required this.chapterLinkDom,
    required this.chapterNameDom,
    required this.chapterDateDom,
  });

  factory MhDetail.fromJson(Map<String, dynamic>? j) => MhDetail(
    coverDom: (j?['coverDom'] as String?) ?? '.detail-main-cover img',
    titleDom: (j?['titleDom'] as String?) ?? '.detail-main-info-title',
    authorDom: (j?['authorDom'] as String?) ?? '.detail-main-info-author a',
    descDom: (j?['descDom'] as String?) ?? '.detail-desc',
    tagDom: (j?['tagDom'] as String?) ?? '.detail-main-info-class span a',
    chapterGroupDom:
        (j?['chapterGroupDom'] as String?) ?? 'ul[id^="detail-list-select-"]',
    chapterItemDom: (j?['chapterItemDom'] as String?) ?? 'li',
    chapterLinkDom: (j?['chapterLinkDom'] as String?) ?? 'a.chapteritem',
    chapterNameDom:
        (j?['chapterNameDom'] as String?) ?? '.detail-list-2-info-title',
    chapterDateDom:
        (j?['chapterDateDom'] as String?) ?? '.detail-list-2-info-subtitle',
  );

  Map<String, dynamic> toJson() => {
    'coverDom': coverDom,
    'titleDom': titleDom,
    'authorDom': authorDom,
    'descDom': descDom,
    'tagDom': tagDom,
    'chapterGroupDom': chapterGroupDom,
    'chapterItemDom': chapterItemDom,
    'chapterLinkDom': chapterLinkDom,
    'chapterNameDom': chapterNameDom,
    'chapterDateDom': chapterDateDom,
  };
}

/// 章节图接口配置（章节页 HTML 内 Dean-Edwards packer 解包）。
class MhChapterImage {
  /// packer 解包后图片 URL 数组的变量名。
  final String imageArrayVar;

  /// 是否将 packer 中的图片 URL 协议匹配前缀（https/http）。
  /// manhuaren 解包后 URL 完整带协议，无需补全；个别 dm5 系姊妹站可能给 //host 开头，需补 https:。
  final bool ensureHttps;

  const MhChapterImage({
    required this.imageArrayVar,
    required this.ensureHttps,
  });

  factory MhChapterImage.fromJson(Map<String, dynamic>? j) => MhChapterImage(
    imageArrayVar: (j?['imageArrayVar'] as String?) ?? 'newImgs',
    ensureHttps: (j?['ensureHttps'] as bool?) ?? true,
  );

  Map<String, dynamic> toJson() => {
    'imageArrayVar': imageArrayVar,
    'ensureHttps': ensureHttps,
  };
}
