// 漫画源通用模型（跨源统一）。
//
// CManga/CChapter 对齐 Mihon 的 SManga/SChapter，字段贴近现有 Comic/ComicChapter，
// 以保证适配层极薄、现有 UI/下载/阅读代码几乎不动。
//
// 多源主键：CManga.id 为「源内唯一标识」（copymanga=pathWord，配置源=详情页相对 URL），
// 跨源唯一 key 由 `sourceId + id` 组合（见 SourceManager / DownloadService 的 key 迁移）。

/// 通用漫画模型
class CManga {
  final String id; // 源内唯一标识
  final String sourceId; // 所属源 id
  final String title;
  final String cover;
  final String? author;
  final String? alias;
  final String? description;
  final String? status; // 保留源原始状态字符串（兼容现有 UI 显示，不强行枚举化）
  final List<String>? tags;
  final double? rating;
  final int? popular;
  final String? url; // 详情页 URL（多源用；copymanga 以 pathWord 为标识，可空）
  final int? totalChapters;
  final DateTime? updateTime;
  final bool initialized; // 是否已补全详情

  const CManga({
    required this.id,
    required this.sourceId,
    required this.title,
    this.cover = '',
    this.author,
    this.alias,
    this.description,
    this.status,
    this.tags,
    this.rating,
    this.popular,
    this.url,
    this.totalChapters,
    this.updateTime,
    this.initialized = false,
  });

  CManga copyWith({
    String? id,
    String? sourceId,
    String? title,
    String? cover,
    String? author,
    String? alias,
    String? description,
    String? status,
    List<String>? tags,
    double? rating,
    int? popular,
    String? url,
    int? totalChapters,
    DateTime? updateTime,
    bool? initialized,
  }) {
    return CManga(
      id: id ?? this.id,
      sourceId: sourceId ?? this.sourceId,
      title: title ?? this.title,
      cover: cover ?? this.cover,
      author: author ?? this.author,
      alias: alias ?? this.alias,
      description: description ?? this.description,
      status: status ?? this.status,
      tags: tags ?? this.tags,
      rating: rating ?? this.rating,
      popular: popular ?? this.popular,
      url: url ?? this.url,
      totalChapters: totalChapters ?? this.totalChapters,
      updateTime: updateTime ?? this.updateTime,
      initialized: initialized ?? this.initialized,
    );
  }
}

/// 通用章节模型
class CChapter {
  final String id; // 源内章节唯一标识
  final String sourceId;
  final String mangaId; // 所属漫画在源内的 id
  final String name;
  final String? url; // 章节页 URL（取图用）
  final int order;
  final int? count;
  final String? groupId; // 分组 id（无分组概念的源可空，适配层按它重组 ChapterGroup）
  final String? groupName;
  final DateTime? createTime;
  final double? chapterNumber;

  const CChapter({
    required this.id,
    required this.sourceId,
    required this.mangaId,
    required this.name,
    this.url,
    this.order = 0,
    this.count,
    this.groupId,
    this.groupName,
    this.createTime,
    this.chapterNumber,
  });
}

/// 搜索/分类结果页
class MangasPage {
  final List<CManga> items;
  final bool hasNextPage;
  final int? total;

  const MangasPage({
    required this.items,
    required this.hasNextPage,
    this.total,
  });
}

/// 分类/筛选器基类（阶段2 扩展 SelectFilter/TextFilter/TriStateFilter/SortFilter 等子类）
sealed class SourceFilter {}

/// 筛选器集合
class FilterList {
  final List<SourceFilter> list;
  const FilterList([this.list = const []]);
}

/// 分类筛选的一个选项（如「少年」value=3262、「A」value=a）。
///
/// value 是传给源接口的值；name 是显示名；isAll 标记「全部」
/// （选中或未选即该维度不参与筛选）。
class FilterOption {
  final String value;
  final String name;
  final bool isAll;

  const FilterOption({
    required this.value,
    required this.name,
    this.isAll = false,
  });
}

/// 分类的一个维度（如「受众」「题材」），组内单选，多组叠加为 AND 筛选。
///
/// key 为维度标识，也是传给源接口的参数名（如 audience/cate/theme）。
/// selected 为 null 或指向 isAll 选项时，该维度不参与筛选。
class FilterGroup {
  final String key;
  final String title;
  final List<FilterOption> options;
  final FilterOption? selected;

  const FilterGroup({
    required this.key,
    required this.title,
    required this.options,
    this.selected,
  });

  /// 复制；clearSelected=true 时把选中清为 null（用于「重置」）。
  FilterGroup copyWith({FilterOption? selected, bool clearSelected = false}) =>
      FilterGroup(
        key: key,
        title: title,
        options: options,
        selected: clearSelected ? null : (selected ?? this.selected),
      );

  /// 该维度是否实际参与筛选（有选中且非「全部」）
  bool get isActive => selected != null && !selected!.isAll;
}
