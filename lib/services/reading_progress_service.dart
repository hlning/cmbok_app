import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/bookshelf.dart';
import '../models/comic.dart';
import 'bookshelf_service.dart';

/// 日志工具
void _log(String message) {
  if (kDebugMode) {
    debugPrint('[ReadingProgress] $message');
  }
}

/// 单本漫画的阅读进度
class ComicReadingProgress {
  /// 续读章节 id
  final String lastChapterId;
  final String lastChapterTitle;
  final int lastChapterOrder;

  /// 续读章节在章节列表中的排序位置（从 0 起，-1 表示未知）
  final int lastChapterIndex;

  /// 续读页码（从 0 起）
  final int lastPageIndex;

  /// 是否已读完（最后一话的最后一页）；书架归位与启动回填用
  final bool finished;

  /// 已读（至少打开过）的章节 id 集合
  final Set<String> seenChapterIds;

  /// 最近更新时间戳（ms）
  final int updatedAt;

  const ComicReadingProgress({
    required this.lastChapterId,
    required this.lastChapterTitle,
    required this.lastChapterOrder,
    required this.lastChapterIndex,
    required this.lastPageIndex,
    required this.finished,
    required this.seenChapterIds,
    required this.updatedAt,
  });

  factory ComicReadingProgress.fromJson(Map<String, dynamic> j) {
    final seen = <String>{};
    final raw = j['seenChapterIds'];
    if (raw is List) {
      for (final id in raw) {
        if (id is String && id.isNotEmpty) seen.add(id);
      }
    }
    return ComicReadingProgress(
      lastChapterId: j['lastChapterId'] as String? ?? '',
      lastChapterTitle: j['lastChapterTitle'] as String? ?? '',
      lastChapterOrder: j['lastChapterOrder'] as int? ?? 0,
      lastChapterIndex: j['lastChapterIndex'] as int? ?? -1,
      lastPageIndex: j['lastPageIndex'] as int? ?? 0,
      finished: j['finished'] as bool? ?? false,
      seenChapterIds: seen,
      updatedAt: j['updatedAt'] as int? ?? 0,
    );
  }

  Map<String, dynamic> toJson() => {
    'lastChapterId': lastChapterId,
    'lastChapterTitle': lastChapterTitle,
    'lastChapterOrder': lastChapterOrder,
    'lastChapterIndex': lastChapterIndex,
    'lastPageIndex': lastPageIndex,
    'finished': finished,
    'seenChapterIds': seenChapterIds.toList(),
    'updatedAt': updatedAt,
  };

  ComicReadingProgress copyWith({
    String? lastChapterId,
    String? lastChapterTitle,
    int? lastChapterOrder,
    int? lastChapterIndex,
    int? lastPageIndex,
    bool? finished,
    Set<String>? seenChapterIds,
    int? updatedAt,
  }) {
    return ComicReadingProgress(
      lastChapterId: lastChapterId ?? this.lastChapterId,
      lastChapterTitle: lastChapterTitle ?? this.lastChapterTitle,
      lastChapterOrder: lastChapterOrder ?? this.lastChapterOrder,
      lastChapterIndex: lastChapterIndex ?? this.lastChapterIndex,
      lastPageIndex: lastPageIndex ?? this.lastPageIndex,
      finished: finished ?? this.finished,
      seenChapterIds: seenChapterIds ?? this.seenChapterIds,
      updatedAt: updatedAt ?? this.updatedAt,
    );
  }
}

/// 阅读进度服务（单例 + ChangeNotifier）
/// 按漫画 pathWord 记录续读章节/页码与已读章节集合，持久化到 SharedPreferences。
/// UI 用 ListenableBuilder 或 addListener 监听变化。
class ReadingProgressService extends ChangeNotifier {
  ReadingProgressService._();
  static final ReadingProgressService _instance = ReadingProgressService._();
  factory ReadingProgressService() => _instance;

  static const _key = 'reading_progress';

  /// 自动归位"正在读"书架的已读章节阈值：读过这么多不同章节才算"正在读"，
  /// 避免只瞄几眼（点开一两个章节）就污染正在读书架。
  static const int readingShelfThreshold = 5;

  final Map<String, ComicReadingProgress> _map = {};

  /// updatePageIndex 节流时间戳：翻页时最多 1 秒通知一次，避免频繁重建监听方
  int _lastPageNotifyAt = 0;

  /// 初始化：从本地加载
  Future<void> init() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_key);
      if (raw != null) {
        final obj = jsonDecode(raw) as Map<String, dynamic>;
        for (final entry in obj.entries) {
          if (entry.value is Map) {
            _map[entry.key] = ComicReadingProgress.fromJson(
              Map<String, dynamic>.from(entry.value as Map),
            );
          }
        }
      }
      _log('已加载 ${_map.length} 本漫画阅读进度');
    } catch (e) {
      _log('加载阅读进度失败: $e');
    }
    await _syncReadingStatus();
    notifyListeners();
  }

  /// 启动回填：按 finished 标志把有阅读记录的漫画归位到"正在读"/"已读完"。
  /// meta 从已有书架条目取快照（与收藏解耦）。
  Future<void> _syncReadingStatus() async {
    if (_map.isEmpty) {
      return;
    }
    for (final pathWord in _map.keys) {
      final p = _map[pathWord]!;
      // 读完->已读完；未读完且已读达阈值->正在读；不足阈值不归位（避免瞄几眼就进正在读）
      final String target;
      if (p.finished) {
        target = BookshelfService.presetFinished;
      } else if (p.seenChapterIds.length >= readingShelfThreshold ||
          _isDownloadedComic(pathWord)) {
        target = BookshelfService.presetReading;
      } else {
        continue;
      }
      final meta = BookshelfService().findItemMeta(
        pathWord,
        BookshelfItemType.comic,
      );
      if (meta == null) {
        continue; // 无快照无法展示，跳过
      }
      await BookshelfService().moveBetweenStatusShelves(
        bookId: pathWord,
        type: BookshelfItemType.comic,
        toShelf: target,
        meta: meta,
      );
    }
  }

  Future<void> _persist() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final obj = <String, dynamic>{};
      for (final entry in _map.entries) {
        obj[entry.key] = entry.value.toJson();
      }
      await prefs.setString(_key, jsonEncode(obj));
    } catch (e) {
      _log('保存阅读进度失败: $e');
    }
  }

  /// 所有有阅读记录的漫画 pathWord（回填"正在读"用）
  Iterable<String> get pathWords => _map.keys;

  /// 获取某本漫画的阅读进度（无则 null）
  ComicReadingProgress? getProgress(String pathWord) => _map[pathWord];

  /// 章节是否已读（至少打开过）
  bool isChapterSeen(String pathWord, String chapterId) {
    return _map[pathWord]?.seenChapterIds.contains(chapterId) ?? false;
  }

  /// 获取最近阅读的漫画（按 updatedAt 倒序取第一条），返回 (pathWord, progress)
  MapEntry<String, ComicReadingProgress>? getMostRecent() {
    if (_map.isEmpty) return null;
    String? bestKey;
    ComicReadingProgress? best;
    _map.forEach((k, v) {
      if (best == null || v.updatedAt > best!.updatedAt) {
        bestKey = k;
        best = v;
      }
    });
    return bestKey != null ? MapEntry(bestKey!, best!) : null;
  }

  /// 记录打开某章节：更新续读点与已读集合，pageIndex 为当前页。
  /// 触发持久化与 notifyListeners（章节切换时进度变化，UI 需刷新）。
  void recordChapter(
    String pathWord,
    ComicChapter chapter,
    int pageIndex,
    int chapterIndex,
  ) {
    final existing = _map[pathWord];
    final seen = existing?.seenChapterIds ?? <String>{};
    seen.add(chapter.id);
    _map[pathWord] = ComicReadingProgress(
      lastChapterId: chapter.id,
      lastChapterTitle: chapter.title,
      lastChapterOrder: chapter.order,
      lastChapterIndex: chapterIndex,
      lastPageIndex: pageIndex,
      finished: existing?.finished ?? false,
      seenChapterIds: seen,
      updatedAt: DateTime.now().millisecondsSinceEpoch,
    );
    _persist();
    notifyListeners();
  }

  /// 翻页时更新当前页（仅当章节一致）。节流通知监听方（1秒一次），
  /// 让书架在阅读器后台静默重建以触发封面 fade 动画（与图书 recordBlock 一致）；
  /// 不更新 updatedAt（排序仍按切章节时间）。下载页/详情页仅 setState，节流下可接受。
  void updatePageIndex(String pathWord, String chapterId, int pageIndex) {
    final p = _map[pathWord];
    if (p == null || p.lastChapterId != chapterId) return;
    if (p.lastPageIndex == pageIndex) return;
    _map[pathWord] = p.copyWith(lastPageIndex: pageIndex);
    _persist();
    final now = DateTime.now().millisecondsSinceEpoch;
    if (now - _lastPageNotifyAt >= 1000) {
      _lastPageNotifyAt = now;
      notifyListeners();
    }
  }

  /// 该漫画是否在"已下载的书"书架中。
  /// 下载漫画视为明确阅读意图，归位"正在读"时免除章节阈值。
  bool _isDownloadedComic(String pathWord) => BookshelfService().isInBookshelf(
    BookshelfService.presetDownloaded,
    pathWord,
    BookshelfItemType.comic,
  );

  /// 更新"已读完"标志并按状态归位书架（正在读/已读完）。
  /// finished 变化时持久化；书架移动幂等（仅变化时写盘+notify）。
  /// 调用方应自带状态缓存避免频繁调用。
  Future<void> setFinished(
    String pathWord,
    bool finished, {
    String? meta,
  }) async {
    final p = _map[pathWord];
    if (p != null && p.finished != finished) {
      _map[pathWord] = p.copyWith(finished: finished);
      await _persist();
    }
    // 读完->已读完；未读完且已读达阈值才归位"正在读"，避免只看几眼就污染正在读书架
    if (finished) {
      await BookshelfService().moveBetweenStatusShelves(
        bookId: pathWord,
        type: BookshelfItemType.comic,
        toShelf: BookshelfService.presetFinished,
        meta: meta,
      );
    } else if (p != null &&
        (p.seenChapterIds.length >= readingShelfThreshold ||
            _isDownloadedComic(pathWord))) {
      await BookshelfService().moveBetweenStatusShelves(
        bookId: pathWord,
        type: BookshelfItemType.comic,
        toShelf: BookshelfService.presetReading,
        meta: meta,
      );
    }
  }

  /// 清除某本漫画的阅读进度（整本删除下载时调用）
  Future<void> clearComic(String pathWord) async {
    if (_map.remove(pathWord) == null) return;
    await _persist();
    notifyListeners();
  }
}
