import 'models.dart';

/// 漫画源契约（借鉴 Mihon HttpSource，适配 Flutter/Dio）。
///
/// 各源实现此抽象类，对外统一「搜索/分类/详情/章节/取图」接口。
/// 取图方法 [getChapterImages] 直接返回图片 URL 列表（对齐现有 ComicApi.getChapterImages），
/// 源内部可多步（翻页/WebView/JS 计算），对外只暴露一步，使 ReaderPage/DownloadService 零改动。
abstract class MangaSource {
  /// 全局唯一 id（如 'copymanga' / 'config:lemh'）
  String get id;

  /// 显示名
  String get name;

  /// 语言（ISO 639-1）
  String get lang;

  /// 是否支持「最新」分类
  bool get supportsLatest;

  /// 是否支持「分类浏览」（不支持时搜索页分类按钮置灰）
  bool get supportsCategories => false;

  /// 拉取分类维度列表（弹窗用）；不支持分类的源返回空。
  /// 每个维度 [FilterGroup] 组内单选，多组叠加为 AND。
  Future<List<FilterGroup>> fetchCategories() async => const [];

  /// 按分类维度筛选列出漫画（page 0 起）。
  /// groups 中 selected 为 null 或「全部」的维度不参与筛选。
  Future<MangasPage> getCategoryList(
    List<FilterGroup> groups, {
    int page = 0,
  }) async => const MangasPage(items: [], hasNextPage: false);

  /// 搜索（query 为空时按 [filters] 分类浏览）
  Future<MangasPage> search(
    String query, {
    int page = 0,
    FilterList filters = const FilterList(),
  });

  /// 热门（分类）
  Future<MangasPage> getPopular({int page = 0});

  /// 最新（分类）
  Future<MangasPage> getLatestUpdates({int page = 0});

  /// 该源支持的筛选器（阶段2 分类/高级筛选用）
  FilterList getFilterList() => const FilterList();

  /// 漫画详情（补全 description/status/cover 等）
  Future<CManga> getMangaDetails(CManga manga);

  /// 章节列表（平铺；有分组概念的源填 groupId/groupName，适配层再重组为 ChapterGroup）
  Future<List<CChapter>> getChapterList(CManga manga);

  /// 详情+章节合并获取（默认拆分调用；源可覆盖以避免重复请求，如 copymanga 的 comic2）
  Future<({CManga manga, List<CChapter> chapters})> getMangaDetailsAndChapters(
    CManga manga,
  ) async {
    final m = await getMangaDetails(manga);
    final c = await getChapterList(manga);
    return (manga: m, chapters: c);
  }

  /// 章节图片 URL 列表（对齐现有 getChapterImages，返回字符串列表）
  Future<List<String>> getChapterImages(CManga manga, CChapter chapter);

  /// 图片下载请求头（防盗链/UA）
  Map<String, String> get imageHeaders => const {
    'User-Agent':
        'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
        '(KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36',
  };

  /// 图片下载 Referer（防盗链）
  String? get referer => null;

  /// 章节图片下载 Referer（防盗链）。
  ///
  /// 默认返回 [referer]（站点首页作统一防盗链，适配大多数源）；
  /// 部分源的图床按章节页 URL 做防盗链校验（manhuaren 等），覆写本方法
  /// 返回当前章节的 URL，使 ReaderPage/DownloadService 能拿到正确的 Referer。
  String? refererForChapter(CChapter chapter) => referer;

  /// 章节列表是否按 order(DOM 顺序)排，跳过智能排序（更新时间序站点如来漫画用）
  bool get chapterSortByOrder => false;

  /// order 方向：false=正序(order 升序=第1话在前)，true=倒序(order 升序=最新在前)。
  /// UI 据此决定 order 升/降序，使主列表统一「第1话在前」。
  /// copymanga(API list 最新在前)=true；manhuaren/zaimanhua(源层已正序)=false；
  /// config 源覆写为 site.chapterOrder==0。
  bool get chapterOrderDescending => false;

  /// 是否需要魔法（代理/VPN）才能访问。
  /// 固有属性，由 SourceManager 从 SourceDefinition.needsMagic 注入；
  /// 代码源（copymanga 等）默认 false。UI 据此在源标签右上角标魔法图标。
  bool needsMagic = false;
}
