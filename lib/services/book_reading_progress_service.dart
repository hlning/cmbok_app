import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/bookshelf.dart';
import 'book_favorites_service.dart';
import 'bookshelf_service.dart';

/// 日志工具
void _log(String message) {
  if (kDebugMode) {
    debugPrint('[BookReadingProgress] $message');
  }
}

/// 单本图书的阅读进度
/// - blockIndex：续读 block 索引（在 BookContent.flatBlocks 中，从 0 起），
///   用于跨排版续读跳转（内容维度，不受字号/屏幕影响）。
/// - pageIndex/pageTotal：阅读百分比用（页维度，与阅读器 HUD 一致）。
class BookReadingProgress {
  /// 续读 block 索引（在 BookContent.flatBlocks 中，从 0 起）
  final int blockIndex;

  /// 续读页索引（阅读器 HUD 百分比用；旧数据为 0）
  final int pageIndex;

  /// 总页数（阅读器 HUD 百分比用；旧数据为 0，此时无法算百分比）
  final int pageTotal;

  /// 最近更新时间戳（ms）
  final int updatedAt;

  const BookReadingProgress({
    required this.blockIndex,
    this.pageIndex = 0,
    this.pageTotal = 0,
    required this.updatedAt,
  });

  factory BookReadingProgress.fromJson(Map<String, dynamic> j) {
    return BookReadingProgress(
      blockIndex: j['blockIndex'] as int? ?? 0,
      pageIndex: j['pageIndex'] as int? ?? 0,
      pageTotal: j['pageTotal'] as int? ?? 0,
      updatedAt: j['updatedAt'] as int? ?? 0,
    );
  }

  Map<String, dynamic> toJson() => {
    'blockIndex': blockIndex,
    'pageIndex': pageIndex,
    'pageTotal': pageTotal,
    'updatedAt': updatedAt,
  };
}

/// 图书阅读进度服务（单例 + ChangeNotifier）
/// 按 bookId 记录续读 blockIndex，持久化到 SharedPreferences。
/// 与漫画 ReadingProgressService 完全隔离（独立 key），零回归。
class BookReadingProgressService extends ChangeNotifier {
  BookReadingProgressService._();
  static final BookReadingProgressService _instance =
      BookReadingProgressService._();
  factory BookReadingProgressService() => _instance;

  static const _key = 'book_reading_progress';

  final Map<String, BookReadingProgress> _map = {};

  /// recordBlock 节流时间戳：翻页时最多 1 秒通知一次，避免快速翻页频繁重建书架
  int _lastBlockNotifyAt = 0;

  /// 初始化：从本地加载
  Future<void> init() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_key);
      if (raw != null) {
        final obj = jsonDecode(raw) as Map<String, dynamic>;
        for (final entry in obj.entries) {
          if (entry.value is Map) {
            _map[entry.key] = BookReadingProgress.fromJson(
              Map<String, dynamic>.from(entry.value as Map),
            );
          }
        }
      }
      _log('已加载 ${_map.length} 本图书阅读进度');
    } catch (e) {
      _log('加载图书阅读进度失败: $e');
    }
    await _syncReadingStatus();
    notifyListeners();
  }

  /// 启动回填：按进度把有阅读记录的图书归位到"正在读"/"已读完"。
  /// meta 取自收藏夹，否则从已有书架条目取快照（本地导入书）。
  Future<void> _syncReadingStatus() async {
    if (_map.isEmpty) {
      return;
    }
    final books = BookFavoritesService().books;
    for (final bookId in _map.keys) {
      final rp = _map[bookId]!;
      final finished = rp.pageTotal > 0 && rp.pageIndex + 1 >= rp.pageTotal;
      final target = finished
          ? BookshelfService.presetFinished
          : BookshelfService.presetReading;
      String? meta;
      try {
        meta = jsonEncode(books.firstWhere((b) => b.id == bookId).toJson());
      } catch (_) {
        meta = BookshelfService().findItemMeta(bookId, BookshelfItemType.book);
      }
      if (meta == null) {
        continue; // 无快照无法展示，跳过
      }
      await BookshelfService().moveBetweenStatusShelves(
        bookId: bookId,
        type: BookshelfItemType.book,
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
      _log('保存图书阅读进度失败: $e');
    }
  }

  /// 所有有阅读记录的图书 bookId（回填"正在读"用）
  Iterable<String> get bookIds => _map.keys;

  /// 获取某本图书的阅读进度（无则 null）
  BookReadingProgress? getProgress(String bookId) => _map[bookId];

  /// 通知监听方刷新进度展示（如退出阅读器后刷新书架进度徽标）。
  /// recordBlock 故意不 notify，需在合适时机手动触发。
  void notifyProgressChanged() => notifyListeners();

  /// 记录续读 block 索引并持久化。[notify]=true 时按节流策略通知书架重排
  /// （翻页时书架在阅读器后台不可见，静默重建重排，退出时即已为新排序）。
  /// 节流：最多 1 秒通知一次，避免快速翻页频繁重建；dispose 兜底落盘传 false 不通知。
  void recordBlock(
    String bookId,
    int blockIndex,
    int pageIndex,
    int pageTotal, {
    bool notify = true,
  }) {
    final existing = _map[bookId];
    if (existing != null &&
        existing.blockIndex == blockIndex &&
        existing.pageIndex == pageIndex &&
        existing.pageTotal == pageTotal) {
      return;
    }
    _map[bookId] = BookReadingProgress(
      blockIndex: blockIndex,
      pageIndex: pageIndex,
      pageTotal: pageTotal,
      updatedAt: DateTime.now().millisecondsSinceEpoch,
    );
    _persist();
    if (notify) {
      final now = DateTime.now().millisecondsSinceEpoch;
      if (now - _lastBlockNotifyAt >= 1000) {
        _lastBlockNotifyAt = now;
        notifyListeners();
      }
    }
  }

  /// 清除某本图书的阅读进度（删除下载时调用）
  Future<void> clearBook(String bookId) async {
    if (_map.remove(bookId) == null) return;
    await _persist();
    notifyListeners();
  }
}
