// 再漫画源（API 驱动 SPA）的可变配置。
//
// 把 ZaimanhuaSource 里会随网站改版而变的「数据」抽出来：base/路径/字段映射/包络/分类维度，
// 代码逻辑骨架（_get 校验流程、章节分组解析、firstLetter/sortType quirk、热度解析、下架检测）保留。
// 网站换域名/路径/字段名时，更新此配置（本地 JSON 或远端）即可，无需发版。
//
// 所有字段带默认值（= 当前线上 zaimanhua 的取值），JSON 缺字段也能正常工作，便于渐进配置。

/// 合并默认字段映射与传入覆盖（传入的 key 覆盖默认，未传的保留默认）。
Map<String, String> _strMap(dynamic j, Map<String, String> defaults) {
  final m = Map<String, String>.from(defaults);
  if (j is Map) {
    j.forEach((k, v) {
      if (k is String && v != null) m[k] = '$v';
    });
  }
  return m;
}

/// 再漫画源完整配置。
class ZaimanhuaConfig {
  /// 全局唯一 id（协议标识，默认 'zaimanhua'，对齐 ZaimanhuaSource.id 与 currentSourceId 持久化）。
  final String id;

  /// 站点首页（API base）。
  final String base;

  /// 请求 UA。
  final String ua;

  final ZEnvelope envelope;
  final ZSearch search;
  final ZCategory category;
  final ZDetail detail;
  final ZChapterImage chapterImage;

  /// 热度字符串单位映射（如 {"万":10000,"千":1000}）。
  final Map<String, int> hotUnits;

  /// 下架状态文案 / 详情提示前缀。
  final String delistedStatus;
  final String delistedTextPrefix;

  const ZaimanhuaConfig({
    required this.id,
    required this.base,
    required this.ua,
    required this.envelope,
    required this.search,
    required this.category,
    required this.detail,
    required this.chapterImage,
    required this.hotUnits,
    required this.delistedStatus,
    required this.delistedTextPrefix,
  });

  static const _defaultUa =
      'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
      '(KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36';

  factory ZaimanhuaConfig.fromJson(Map<String, dynamic> j) => ZaimanhuaConfig(
    id: (j['id'] as String?) ?? 'zaimanhua',
    base: (j['base'] as String?) ?? 'https://manhua.zaimanhua.com/',
    ua: (j['ua'] as String?) ?? _defaultUa,
    envelope: ZEnvelope.fromJson(j['envelope'] as Map<String, dynamic>?),
    search: ZSearch.fromJson(j['search'] as Map<String, dynamic>?),
    category: ZCategory.fromJson(j['category'] as Map<String, dynamic>?),
    detail: ZDetail.fromJson(j['detail'] as Map<String, dynamic>?),
    chapterImage: ZChapterImage.fromJson(
      j['chapterImage'] as Map<String, dynamic>?,
    ),
    hotUnits: _parseHotUnits(j['hotUnits']),
    delistedStatus: (j['delistedStatus'] as String?) ?? '已下架',
    delistedTextPrefix:
        (j['delistedTextPrefix'] as String?) ?? '⚠️ 该漫画章节已被源站下架删除，暂无法阅读',
  );

  static Map<String, int> _parseHotUnits(dynamic j) {
    if (j is! Map) return const {'万': 10000, '千': 1000};
    final m = <String, int>{};
    j.forEach((k, v) {
      if (k is String) m[k] = (v is num ? v.toInt() : int.tryParse('$v') ?? 0);
    });
    return m.isEmpty ? const {'万': 10000, '千': 1000} : m;
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'base': base,
    'ua': ua,
    'envelope': envelope.toJson(),
    'search': search.toJson(),
    'category': category.toJson(),
    'detail': detail.toJson(),
    'chapterImage': chapterImage.toJson(),
    'hotUnits': hotUnits,
    'delistedStatus': delistedStatus,
    'delistedTextPrefix': delistedTextPrefix,
  };
}

/// 响应包络：{errno:0, data:..., errmsg:...}
class ZEnvelope {
  final String codeField;
  final String dataField;
  final String msgField;
  final int successCode;

  const ZEnvelope({
    required this.codeField,
    required this.dataField,
    required this.msgField,
    required this.successCode,
  });

  factory ZEnvelope.fromJson(Map<String, dynamic>? j) => ZEnvelope(
    codeField: (j?['codeField'] as String?) ?? 'errno',
    dataField: (j?['dataField'] as String?) ?? 'data',
    msgField: (j?['msgField'] as String?) ?? 'errmsg',
    successCode: (j?['successCode'] as num?)?.toInt() ?? 0,
  );

  Map<String, dynamic> toJson() => {
    'codeField': codeField,
    'dataField': dataField,
    'msgField': msgField,
    'successCode': successCode,
  };
}

/// 搜索接口配置。
class ZSearch {
  final String path;
  final String queryKey; // 关键词参数名
  final String pageKey; // 页码参数名
  final String sizeKey; // 每页条数参数名
  final int size; // 每页条数（同时用于 hasNextPage 判断）
  final String listField; // 结果列表字段
  final String idField; // 单条结果的 id 字段
  final Map<String, String> fields; // title/cover/authors/status/hot

  const ZSearch({
    required this.path,
    required this.queryKey,
    required this.pageKey,
    required this.sizeKey,
    required this.size,
    required this.listField,
    required this.idField,
    required this.fields,
  });

  factory ZSearch.fromJson(Map<String, dynamic>? j) => ZSearch(
    path: (j?['path'] as String?) ?? 'app/v1/search/index',
    queryKey: (j?['queryKey'] as String?) ?? 'keyword',
    pageKey: (j?['pageKey'] as String?) ?? 'page',
    sizeKey: (j?['sizeKey'] as String?) ?? 'size',
    size: (j?['size'] as num?)?.toInt() ?? 20,
    listField: (j?['listField'] as String?) ?? 'list',
    idField: (j?['idField'] as String?) ?? 'id',
    fields: _strMap(j?['fields'], const {
      'title': 'title',
      'cover': 'cover',
      'authors': 'authors',
      'status': 'status',
      'hot': 'hot_hits',
    }),
  );

  Map<String, dynamic> toJson() => {
    'path': path,
    'queryKey': queryKey,
    'pageKey': pageKey,
    'sizeKey': sizeKey,
    'size': size,
    'listField': listField,
    'idField': idField,
    'fields': fields,
  };
}

/// 分类浏览接口配置。
class ZCategory {
  final String filterTypePath; // 分类维度列表
  final String filterPath; // 按维度筛选
  final Map<String, String> titles; // 维度 key -> 显示名（顺序即展示顺序）
  final String listField; // 结果列表字段
  final String totalField; // 总数字段
  final String idField; // 单条结果 id 字段
  final String optionNameField; // 维度选项的 name 字段
  final Map<String, String> fields; // name/cover/authors/status

  const ZCategory({
    required this.filterTypePath,
    required this.filterPath,
    required this.titles,
    required this.listField,
    required this.totalField,
    required this.idField,
    required this.optionNameField,
    required this.fields,
  });

  factory ZCategory.fromJson(Map<String, dynamic>? j) => ZCategory(
    filterTypePath:
        (j?['filterTypePath'] as String?) ?? 'api/v1/comic1/filter_type',
    filterPath: (j?['filterPath'] as String?) ?? 'api/v1/comic1/filter',
    titles: _strMap(j?['titles'], const {
      'sortType': '排序',
      'audience': '受众',
      'cate': '类别',
      'firstLetter': '首字母',
      'status': '状态',
      'theme': '题材',
    }),
    listField: (j?['listField'] as String?) ?? 'comicList',
    totalField: (j?['totalField'] as String?) ?? 'totalNum',
    idField: (j?['idField'] as String?) ?? 'id',
    optionNameField: (j?['optionNameField'] as String?) ?? 'name',
    fields: _strMap(j?['fields'], const {
      'name': 'name',
      'cover': 'cover',
      'authors': 'authors',
      'status': 'status',
    }),
  );

  Map<String, dynamic> toJson() => {
    'filterTypePath': filterTypePath,
    'filterPath': filterPath,
    'titles': titles,
    'listField': listField,
    'totalField': totalField,
    'idField': idField,
    'optionNameField': optionNameField,
    'fields': fields,
  };
}

/// 详情+章节接口配置。
class ZDetail {
  final String path;
  final String idKey; // 漫画 id 的 query 参数名
  final String infoField; // 漫画信息字段
  final Map<String, String> fields; // title/cover/description/hotStr
  final Map<String, String> tagFields; // authors/status/tagName
  final String canReadField; // 可读性字段（false 表示下架）
  final String chapterListField; // 章节分组列表字段
  final String groupTitleField; // 分组标题字段
  final String groupDataField; // 分组内章节数组字段
  final Map<String, String> chapterFields; // id/title/order/updateTime

  const ZDetail({
    required this.path,
    required this.idKey,
    required this.infoField,
    required this.fields,
    required this.tagFields,
    required this.canReadField,
    required this.chapterListField,
    required this.groupTitleField,
    required this.groupDataField,
    required this.chapterFields,
  });

  factory ZDetail.fromJson(Map<String, dynamic>? j) => ZDetail(
    path: (j?['path'] as String?) ?? 'api/v1/comic2/comic/detail',
    idKey: (j?['idKey'] as String?) ?? 'id',
    infoField: (j?['infoField'] as String?) ?? 'comicInfo',
    fields: _strMap(j?['fields'], const {
      'title': 'title',
      'cover': 'cover',
      'description': 'description',
      'hotStr': 'hotNumStr',
    }),
    tagFields: _strMap(j?['tagFields'], const {
      'authors': 'authorsTagList',
      'status': 'statusTagList',
      'tagName': 'tagName',
    }),
    canReadField: (j?['canReadField'] as String?) ?? 'canRead',
    chapterListField: (j?['chapterListField'] as String?) ?? 'chapterList',
    groupTitleField: (j?['groupTitleField'] as String?) ?? 'title',
    groupDataField: (j?['groupDataField'] as String?) ?? 'data',
    chapterFields: _strMap(j?['chapterFields'], const {
      'id': 'chapter_id',
      'title': 'chapter_title',
      'order': 'chapter_order',
      'updateTime': 'updatetime',
    }),
  );

  Map<String, dynamic> toJson() => {
    'path': path,
    'idKey': idKey,
    'infoField': infoField,
    'fields': fields,
    'tagFields': tagFields,
    'canReadField': canReadField,
    'chapterListField': chapterListField,
    'groupTitleField': groupTitleField,
    'groupDataField': groupDataField,
    'chapterFields': chapterFields,
  };
}

/// 取图接口配置。
class ZChapterImage {
  final String path;
  final String comicIdKey; // comic_id 参数名
  final String chapterIdKey; // chapter_id 参数名
  final String infoField; // 章节信息字段
  final String pageUrlField; // 图片 URL 列表字段

  const ZChapterImage({
    required this.path,
    required this.comicIdKey,
    required this.chapterIdKey,
    required this.infoField,
    required this.pageUrlField,
  });

  factory ZChapterImage.fromJson(Map<String, dynamic>? j) => ZChapterImage(
    path: (j?['path'] as String?) ?? 'api/v1/comic2/chapter/detail',
    comicIdKey: (j?['comicIdKey'] as String?) ?? 'comic_id',
    chapterIdKey: (j?['chapterIdKey'] as String?) ?? 'chapter_id',
    infoField: (j?['infoField'] as String?) ?? 'chapterInfo',
    pageUrlField: (j?['pageUrlField'] as String?) ?? 'page_url',
  );

  Map<String, dynamic> toJson() => {
    'path': path,
    'comicIdKey': comicIdKey,
    'chapterIdKey': chapterIdKey,
    'infoField': infoField,
    'pageUrlField': pageUrlField,
  };
}
