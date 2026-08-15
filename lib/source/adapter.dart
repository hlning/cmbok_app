import '../models/comic.dart';
import '../models/search_result.dart';
import 'models.dart';

/// CManga ↔ Comic / CChapter ↔ ComicChapter / MangasPage ↔ SearchResult 适配层。
///
/// 设计目标：现有 UI/下载/阅读代码几乎不动，仅把数据来源从 ComicApi 换成 SourceManager.current。
/// 多源主键经此层映射回 copymanga 语义的 Comic/ComicChapter，UI 无感。

/// Comic -> CManga
CManga comicToCManga(Comic c, String sourceId) => CManga(
  id: c.pathWord,
  sourceId: sourceId,
  title: c.title,
  cover: c.cover,
  author: c.author,
  alias: c.alias,
  description: c.description,
  status: c.status,
  tags: c.tags,
  rating: c.rating,
  popular: c.popular,
  totalChapters: c.totalChapters,
  updateTime: c.updateTime,
  initialized: c.description != null,
);

/// CManga -> Comic
///
/// 注意：copymanga 源下 CManga.id 即 pathWord；其他源 CManga.id 是源内标识，
/// 映射到 Comic.pathWord 仅为复用现有以 pathWord 为主键的 UI/下载逻辑（多源下应配合
/// DownloadTask 的复合 key sourceId/mangaId 使用，不依赖 pathWord 跨源唯一）。
Comic cmangaToComic(CManga m) => Comic(
  id: m.id,
  title: m.title,
  cover: m.cover,
  author: m.author,
  alias: m.alias,
  description: m.description,
  status: m.status,
  tags: m.tags,
  rating: m.rating,
  popular: m.popular,
  pathWord: m.id,
  sourceId: m.sourceId,
  totalChapters: m.totalChapters,
  updateTime: m.updateTime,
);

/// ComicChapter -> CChapter
CChapter comicChapterToCChapter(
  ComicChapter c,
  String sourceId,
  String mangaId,
) => CChapter(
  id: c.id,
  sourceId: sourceId,
  mangaId: mangaId,
  name: c.title,
  order: c.order,
  count: c.count,
  groupId: c.groupId,
  groupName: c.groupName,
  createTime: c.createTime,
);

/// CChapter -> ComicChapter
ComicChapter cchapterToComicChapter(CChapter c) => ComicChapter(
  id: c.id,
  title: c.name,
  order: c.order,
  count: c.count ?? 0,
  groupId: c.groupId ?? 'default',
  groupName: c.groupName ?? '默认',
  createTime: c.createTime,
);

/// 平铺 CChapter 列表 -> ChapterGroup 分组（按 groupId 重组，保持分组出现顺序与章节顺序）
List<ChapterGroup> cchaptersToGroups(List<CChapter> chapters) {
  final groupOrder = <String>[];
  final groupMap = <String, List<CChapter>>{};
  for (final c in chapters) {
    final gid = c.groupId ?? 'default';
    if (!groupMap.containsKey(gid)) {
      groupOrder.add(gid);
      groupMap[gid] = <CChapter>[];
    }
    groupMap[gid]!.add(c);
  }
  return groupOrder.map((gid) {
    final list = groupMap[gid]!;
    return ChapterGroup(
      id: gid,
      name: list.first.groupName ?? '默认',
      count: list.length,
      chapters: list.map(cchapterToComicChapter).toList(),
    );
  }).toList();
}

/// ChapterGroup 列表 -> 平铺 CChapter 列表
List<CChapter> groupsToCChapters(
  List<ChapterGroup> groups,
  String sourceId,
  String mangaId,
) => groups
    .expand(
      (g) => g.chapters.map(
        (c) => CChapter(
          id: c.id,
          sourceId: sourceId,
          mangaId: mangaId,
          name: c.title,
          order: c.order,
          count: c.count,
          groupId: g.id,
          groupName: g.name,
          createTime: c.createTime,
        ),
      ),
    )
    .toList();

/// MangasPage -> SearchResult（Comic 列表），保持 SearchPage 现有分页逻辑不变
///
/// [currentPage] 为 1-based 当前页（与现有 SearchResult 约定一致）。
/// totalPages 依据 hasNextPage 推导：有下一页则至少为 currentPage+1，否则等于 currentPage，
/// 使 SearchResult.hasMore 等价于 MangasPage.hasNextPage。
SearchResult<Comic> mangasPageToSearchResult(
  MangasPage page, {
  required int currentPage,
}) => SearchResult<Comic>(
  items: page.items.map(cmangaToComic).toList(),
  total: page.total ?? page.items.length,
  currentPage: currentPage,
  totalPages: page.hasNextPage ? currentPage + 1 : currentPage,
);
