import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'models.dart';
import 'manga_source.dart';
import 'zaimanhua_config.dart';

void _log(String message) {
  if (kDebugMode) {
    print('[ZaimanhuaSource] $message');
  }
}

/// 再漫画源（API 驱动 SPA）：Nuxt 后端 JSON API。
///
/// 可变数据（base/路径/字段映射/包络/分类维度）抽到 [ZaimanhuaConfig]，网站换域名/路径/字段名
/// 时更新配置即可，无需发版；代码逻辑骨架（_get 校验、章节分组解析、firstLetter/sortType quirk、
/// 热度解析、下架检测）保留在此。接口链路见 [ZaimanhuaConfig] 各 path 字段。
class ZaimanhuaSource extends MangaSource {
  final ZaimanhuaConfig config;
  ZaimanhuaSource(this.config);

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
  String get name => '再漫画';

  @override
  String get lang => 'zh';

  @override
  bool get supportsLatest => false;

  @override
  Map<String, String> get imageHeaders => {'User-Agent': config.ua};

  @override
  String? get referer => config.base;

  /// GET {base}{path}，校验包络 code==successCode，返回 data 字段。
  Future<Map<String, dynamic>> _get(
    String path, {
    Map<String, dynamic>? query,
  }) async {
    final env = config.envelope;
    final resp = await _dio.get<dynamic>(
      config.base + path,
      queryParameters: query,
      options: Options(
        headers: {...imageHeaders, 'Referer': config.base},
        responseType: ResponseType.json,
      ),
    );
    final body = resp.data;
    if (body is! Map<String, dynamic>) {
      throw Exception('再漫画接口返回非 JSON: $path');
    }
    if (body[env.codeField] != env.successCode) {
      throw Exception('再漫画接口错误: ${body[env.msgField]} ($path)');
    }
    return (body[env.dataField] as Map<String, dynamic>?) ?? const {};
  }

  @override
  Future<MangasPage> search(
    String query, {
    int page = 0,
    FilterList filters = const FilterList(),
  }) async {
    final s = config.search;
    final data = await _get(
      s.path,
      query: {
        s.queryKey: query,
        s.pageKey: '${page + 1}',
        s.sizeKey: '${s.size}',
      },
    );
    final list = (data[s.listField] as List?) ?? const [];
    final items = <CManga>[];
    for (final item in list) {
      if (item is! Map<String, dynamic>) continue;
      final f = s.fields;
      items.add(
        CManga(
          id: '${item[s.idField]}',
          sourceId: id,
          title: (item[f['title']] ?? '').toString(),
          cover: (item[f['cover']] ?? '').toString(),
          author: (item[f['authors']] ?? '').toString(),
          status: (item[f['status']] ?? '').toString(),
          popular: (item[f['hot']] as num?)?.toInt(),
          url: config.base,
        ),
      );
    }
    _log('搜索: "$query", 第${page + 1}页 ${items.length} 条');
    return MangasPage(items: items, hasNextPage: items.length >= s.size);
  }

  @override
  Future<MangasPage> getPopular({int page = 0}) async =>
      const MangasPage(items: [], hasNextPage: false);

  @override
  Future<MangasPage> getLatestUpdates({int page = 0}) async =>
      const MangasPage(items: [], hasNextPage: false);

  @override
  bool get supportsCategories => true;

  /// firstLetter 维度的值字段是 val，其余维度是 id（zaimanhua 接口 quirk，保留为代码逻辑）。
  static bool _useVal(String key) => key == 'firstLetter';

  @override
  Future<List<FilterGroup>> fetchCategories() async {
    final cat = config.category;
    final data = await _get(cat.filterTypePath);
    final groups = <FilterGroup>[];
    for (final entry in cat.titles.entries) {
      final arr = (data[entry.key] as List?) ?? const [];
      final options = <FilterOption>[];
      for (final o in arr) {
        if (o is! Map<String, dynamic>) continue;
        final rawVal = _useVal(entry.key) ? o['val'] : o['id'];
        final val = rawVal?.toString() ?? '';
        // sortType 维度：热门(id=1) 接口返回空 comicList（后端异常），仅留更新时间(id=0)
        if (entry.key == 'sortType' && val == '1') continue;
        final name = (o[cat.optionNameField] ?? '').toString();
        // id=0 或 val='' 均为「全部」
        options.add(
          FilterOption(
            value: val,
            name: name,
            isAll: val == '0' || val.isEmpty,
          ),
        );
      }
      if (options.isEmpty) continue;
      groups.add(
        FilterGroup(key: entry.key, title: entry.value, options: options),
      );
    }
    _log('分类维度: ${groups.length} 组');
    return groups;
  }

  @override
  Future<MangasPage> getCategoryList(
    List<FilterGroup> groups, {
    int page = 0,
  }) async {
    final cat = config.category;
    final s = config.search;
    final query = <String, dynamic>{
      s.pageKey: '${page + 1}',
      s.sizeKey: '${s.size}',
    };
    for (final g in groups) {
      if (!g.isActive) continue; // 未选/全部 -> 不传该参数
      query[g.key] = g.selected!.value;
    }
    final data = await _get(cat.filterPath, query: query);
    final list = (data[cat.listField] as List?) ?? const [];
    final f = cat.fields;
    final items = <CManga>[];
    for (final item in list) {
      if (item is! Map<String, dynamic>) continue;
      items.add(
        CManga(
          id: '${item[cat.idField]}',
          sourceId: id,
          title: (item[f['name']] ?? '').toString(), // filter 返回 name 非 title
          cover: (item[f['cover']] ?? '').toString(),
          author: (item[f['authors']] ?? '').toString(),
          status: (item[f['status']] ?? '').toString(),
          url: config.base,
        ),
      );
    }
    final total = (data[cat.totalField] as num?)?.toInt();
    _log('分类筛选: $query, 第${page + 1}页 ${items.length} 条, 共 $total');
    return MangasPage(
      items: items,
      hasNextPage: items.length >= s.size,
      total: total,
    );
  }

  @override
  Future<({CManga manga, List<CChapter> chapters})> getMangaDetailsAndChapters(
    CManga manga,
  ) async {
    final d = config.detail;
    final data = await _get(d.path, query: {d.idKey: manga.id});
    final info = (data[d.infoField] as Map<String, dynamic>?) ?? const {};

    // 章节列表：分组结构 [{title: 分组名, data: [章节]}]
    final chapters = <CChapter>[];
    final chapterList = (info[d.chapterListField] as List?) ?? const [];
    final cf = d.chapterFields;
    for (var gi = 0; gi < chapterList.length; gi++) {
      final group = chapterList[gi] as Map<String, dynamic>;
      final groupName = (group[d.groupTitleField] ?? '连载').toString();
      final groupId = '${manga.id}_$gi';
      final arr = (group[d.groupDataField] as List?) ?? const [];
      for (final ch in arr) {
        if (ch is! Map<String, dynamic>) continue;
        final ts = (ch[cf['updateTime']] as num?)?.toInt();
        chapters.add(
          CChapter(
            id: '${ch[cf['id']]}',
            sourceId: id,
            mangaId: manga.id,
            name: (ch[cf['title']] ?? '').toString(),
            order: (ch[cf['order']] as num?)?.toInt() ?? 0,
            groupId: groupId,
            groupName: groupName,
            createTime: ts != null
                ? DateTime.fromMillisecondsSinceEpoch(ts * 1000)
                : null,
          ),
        );
      }
    }
    // chapter_order 升序（第1话在前；接口默认倒序，最新在前）
    chapters.sort((a, b) => a.order.compareTo(b.order));

    final df = d.fields;
    final desc = info[df['description']];
    final authors = _tagNames(info[d.tagFields['authors']]);
    final tagStatus = _tagNames(info[d.tagFields['status']]);
    // canRead=false 表示漫画被源站下架/章节删除：chapterList 空，但元信息还在
    // （lastUpdateChapterName 可能仍残留历史章名）。检测后标记下架，避免详情页空白 0 章。
    final isDelisted = info[d.canReadField] == false;
    final status = isDelisted
        ? config.delistedStatus
        : (tagStatus.isEmpty ? manga.status : tagStatus);
    String? description;
    if (isDelisted) {
      final base = desc != null ? desc.toString() : (manga.description ?? '');
      description =
          config.delistedTextPrefix + (base.isNotEmpty ? '\n\n$base' : '');
    } else {
      description = desc != null ? desc.toString() : manga.description;
    }
    _log(
      '详情+章节: ${manga.id}, 章节数 ${chapters.length}${isDelisted ? '(已下架)' : ''}',
    );
    return (
      manga: manga.copyWith(
        title: (info[df['title']] ?? manga.title).toString(),
        cover: (info[df['cover']] ?? manga.cover).toString(),
        author: authors.isEmpty ? manga.author : authors,
        description: description,
        status: status,
        popular: _parseHotStr((info[df['hotStr']] ?? '').toString()),
        url: config.base,
        initialized: true,
      ),
      chapters: chapters,
    );
  }

  @override
  Future<CManga> getMangaDetails(CManga manga) async =>
      (await getMangaDetailsAndChapters(manga)).manga;

  @override
  Future<List<CChapter>> getChapterList(CManga manga) async =>
      (await getMangaDetailsAndChapters(manga)).chapters;

  @override
  Future<List<String>> getChapterImages(CManga manga, CChapter chapter) async {
    final ci = config.chapterImage;
    final data = await _get(
      ci.path,
      query: {ci.comicIdKey: manga.id, ci.chapterIdKey: chapter.id},
    );
    final info = (data[ci.infoField] as Map<String, dynamic>?) ?? const {};
    final urls = ((info[ci.pageUrlField] as List?) ?? const [])
        .map((e) => '$e')
        .toList();
    _log('取图: ${manga.id}/${chapter.id}, ${urls.length} 张');
    return urls;
  }

  /// 从 tagList（[{tagName}]）提取名称，逗号拼接。
  String _tagNames(dynamic tagList) {
    if (tagList is! List) return '';
    final nameField = config.detail.tagFields['tagName'] ?? 'tagName';
    final names = <String>[];
    for (final t in tagList) {
      if (t is Map<String, dynamic>) {
        final n = (t[nameField] ?? '').toString();
        if (n.isNotEmpty) names.add(n);
      }
    }
    return names.join(', ');
  }

  /// 解析热度字符串为整数（如 "24万+" -> 240000、"2千+" -> 2000、"79" -> 79）。
  /// 接口 hotNum/hitNum 数字字段恒为 0，仅 hotNumStr 可用。单位映射见 [ZaimanhuaConfig.hotUnits]。
  int? _parseHotStr(String s) {
    if (s.isEmpty) return null;
    final units = config.hotUnits;
    final alt = units.keys.map(RegExp.escape).join('|');
    final re = RegExp(
      r'([\d.]+)\s*('
      '$alt'
      r')?',
    );
    final m = re.firstMatch(s);
    if (m == null) return null;
    final n = double.tryParse(m.group(1)!);
    if (n == null) return null;
    final unit = m.group(2);
    final mult = unit == null ? 1 : (units[unit] ?? 1);
    return (n * mult).toInt();
  }
}
