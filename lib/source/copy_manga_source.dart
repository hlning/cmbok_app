import 'package:flutter/foundation.dart';
import '../services/comic_api.dart';
import 'adapter.dart';
import 'copymanga_config.dart';
import 'models.dart';
import 'manga_source.dart';

void _log(String message) {
  if (kDebugMode) {
    print('[CopyMangaSource] $message');
  }
}

/// 拷贝漫画源（api 引擎）：适配现有 [ComicApi]，实现 [MangaSource] 契约。
///
/// 内部 wrap ComicApi，最小改动不重写 copymanga 逻辑（解密/双路径/请求头均复用 ComicApi）。
/// 可变元数据（id/显示名/Referer/UA）由 [CopymangaConfig] 承载，站点换域名或防盗链策略时
/// 更新 sources.json 即可；baseUrl 仍由 RemoteConfigService 动态给（不进配置）。
class CopyMangaSource extends MangaSource {
  final CopymangaConfig config;
  final ComicApi _api;

  CopyMangaSource(this.config, {ComicApi? api}) : _api = api ?? ComicApi();

  @override
  String get id => config.id;

  @override
  String get name => config.name;

  @override
  String get lang => 'zh';

  @override
  bool get supportsLatest => false;

  /// copymanga 章节列表 API 默认按更新时间倒序（最新在前），order 取 list 顺序后
  /// 升序=最新在前，故标记倒序--UI 降序排得到「第1话在前」。
  @override
  bool get chapterOrderDescending => false;

  @override
  Future<MangasPage> search(
    String query, {
    int page = 0,
    FilterList filters = const FilterList(),
  }) async {
    final result = await _api.searchComic(query, page: page);
    return MangasPage(
      items: result.items.map((c) => comicToCManga(c, id)).toList(),
      hasNextPage: result.hasMore,
      total: result.total,
    );
  }

  @override
  Future<MangasPage> getPopular({int page = 0}) async {
    // TODO(阶段2): copymanga 搜索接口支持 ordering 按热门排序
    return const MangasPage(items: [], hasNextPage: false);
  }

  @override
  Future<MangasPage> getLatestUpdates({int page = 0}) async {
    // TODO(阶段2): copymanga 搜索接口支持 ordering 按更新排序
    return const MangasPage(items: [], hasNextPage: false);
  }

  @override
  bool get supportsCategories => true;

  /// 拷贝漫画题材（拼音 path + 中文名，源自 www.copy3000.com/comics 页题材链接）。
  /// comiket 的 C95~C105 子项均 theme=comiket，合并为「漫展」。
  /// 分类只能走网页 SSR（搜索接口 theme 被忽略），详见记忆 copymanga-theme-category-browse。
  static const _themeOptions = <FilterOption>[
    FilterOption(value: 'aa', name: 'AA'),
    FilterOption(value: 'aiqing', name: '愛情'),
    FilterOption(value: 'baihe', name: '百合'),
    FilterOption(value: 'changtiao', name: '長條'),
    FilterOption(value: 'chongsheng', name: '重生'),
    FilterOption(value: 'chuanyue', name: '穿越'),
    FilterOption(value: 'comiket', name: '漫展'),
    FilterOption(value: 'danmei', name: '耽美'),
    FilterOption(value: 'dongfang', name: '東方'),
    FilterOption(value: 'dushi', name: '都市'),
    FilterOption(value: 'fate', name: 'FATE'),
    FilterOption(value: 'gaoxiao', name: '搞笑'),
    FilterOption(value: 'gedou', name: '格鬥'),
    FilterOption(value: 'hougong', name: '後宮'),
    FilterOption(value: 'huanlexiang', name: '歡樂向'),
    FilterOption(value: 'jianniang', name: '舰娘'),
    FilterOption(value: 'jiecao', name: '节操'),
    FilterOption(value: 'jingji', name: '竞技'),
    FilterOption(value: 'jingsong', name: '惊悚'),
    FilterOption(value: 'jizhan', name: '机战'),
    FilterOption(value: 'kehuan', name: '科幻'),
    FilterOption(value: 'kongbu', name: '恐怖'),
    FilterOption(value: 'lishi', name: '历史'),
    FilterOption(value: 'lizhi', name: '励志'),
    FilterOption(value: 'love', name: 'LoveLive'),
    FilterOption(value: 'maoxian', name: '冒險'),
    FilterOption(value: 'meishi', name: '美食'),
    FilterOption(value: 'mengxi', name: '萌系'),
    FilterOption(value: 'mohuan', name: '魔幻'),
    FilterOption(value: 'qihuan', name: '奇幻'),
    FilterOption(value: 'qingxiaoshuo', name: '轻小说'),
    FilterOption(value: 'qita', name: '其他'),
    FilterOption(value: 'rexue', name: '热血'),
    FilterOption(value: 'shengcun', name: '生存'),
    FilterOption(value: 'shenghuo', name: '生活'),
    FilterOption(value: 'shengui', name: '神鬼'),
    FilterOption(value: 'sige', name: '四格'),
    FilterOption(value: 'teenslove', name: 'TL'),
    FilterOption(value: 'weiniang', name: '伪娘'),
    FilterOption(value: 'wuxia', name: '武侠'),
    FilterOption(value: 'xianxia', name: '仙侠'),
    FilterOption(value: 'xiaoyuan', name: '校园'),
    FilterOption(value: 'xingzhuanhuan', name: '性转换'),
    FilterOption(value: 'xuanyi', name: '悬疑'),
    FilterOption(value: 'yinyuewudao', name: '音乐舞蹈'),
    FilterOption(value: 'yishijie', name: '异世界'),
    FilterOption(value: 'zazhifuzengxiezhenji', name: '雜誌附贈寫真集'),
    FilterOption(value: 'zhaixi', name: '宅系'),
    FilterOption(value: 'zhanzheng', name: '战争'),
    FilterOption(value: 'zhentan', name: '侦探'),
    FilterOption(value: 'zhichang', name: '职场'),
    FilterOption(value: 'zhiyu', name: '治愈'),
    FilterOption(value: 'zhuansheng', name: '转生'),
  ];

  @override
  Future<List<FilterGroup>> fetchCategories() async {
    return [
      FilterGroup(
        key: 'ordering',
        title: '排序',
        options: const [
          FilterOption(value: '-datetime_updated', name: '最新更新'),
          FilterOption(value: '-popular', name: '最热门'),
          FilterOption(value: '-datetime_visited', name: '最多浏览'),
        ],
        // 默认「最新更新」；ordering 无「全部」概念，总有一种排序方式
        selected: const FilterOption(value: '-datetime_updated', name: '最新更新'),
      ),
      FilterGroup(
        key: 'theme',
        title: '题材',
        options: [
          const FilterOption(value: '', name: '全部', isAll: true),
          ..._themeOptions,
        ],
      ),
    ];
  }

  @override
  Future<MangasPage> getCategoryList(
    List<FilterGroup> groups, {
    int page = 0,
  }) async {
    final themeMatched = groups.where((g) => g.key == 'theme');
    final theme = themeMatched.isNotEmpty && themeMatched.first.isActive
        ? themeMatched.first.selected!.value
        : '';
    final sortMatched = groups.where((g) => g.key == 'ordering');
    final ordering = sortMatched.isNotEmpty
        ? (sortMatched.first.selected?.value ?? '-datetime_updated')
        : '-datetime_updated';
    final result = await _api.getCategoryComics(
      theme,
      page: page,
      ordering: ordering,
    );
    _log(
      '分类筛选: theme=$theme, ordering=$ordering, 第${page + 1}页 ${result.items.length} 条',
    );
    return MangasPage(
      items: result.items.map((c) => comicToCManga(c, id)).toList(),
      hasNextPage: result.hasMore,
      total: result.total,
    );
  }

  @override
  Future<CManga> getMangaDetails(CManga manga) async {
    final detail = await _api.getComicDetail(manga.id);
    return comicToCManga(detail, id).copyWith(initialized: true);
  }

  @override
  Future<List<CChapter>> getChapterList(CManga manga) async {
    final groups = await _api.getChapters(manga.id);
    return groupsToCChapters(groups, id, manga.id);
  }

  @override
  Future<({CManga manga, List<CChapter> chapters})> getMangaDetailsAndChapters(
    CManga manga,
  ) async {
    // 覆盖默认实现：copymanga 的详情与分组同属一次 comic2 响应，合并请求避免重复
    final result = await _api.getComicDetailAndChapters(manga.id);
    _log(
      '详情+章节合并获取: ${manga.id}, 章节数 ${result.groups.fold<int>(0, (n, g) => n + g.chapters.length)}',
    );
    return (
      manga: comicToCManga(result.comic, id).copyWith(initialized: true),
      chapters: groupsToCChapters(result.groups, id, manga.id),
    );
  }

  @override
  Future<List<String>> getChapterImages(CManga manga, CChapter chapter) async {
    return _api.getChapterImages(manga.id, chapter.id);
  }

  @override
  Map<String, String> get imageHeaders => {'User-Agent': config.ua};

  @override
  String? get referer => config.referer;
}
