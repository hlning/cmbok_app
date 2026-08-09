import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/bookshelf.dart';

void _log(String message) {
  if (kDebugMode) debugPrint('[Bookshelf] $message');
}

/// 书架服务（单例 + ChangeNotifier）
/// 管理书架分类和书架内的漫画/图书条目，持久化到 SharedPreferences。
/// UI 用 ListenableBuilder 监听变化。
class BookshelfService extends ChangeNotifier {
  BookshelfService._();
  static final BookshelfService _instance = BookshelfService._();
  factory BookshelfService() => _instance;

  static const _kBookshelves = 'bookshelf_list';
  static const _kItems = 'bookshelf_items';

  final List<Bookshelf> _bookshelves = [];
  final List<BookshelfItem> _items = [];

  /// 所有书架（按 sortOrder 排序）
  List<Bookshelf> get bookshelves => List.unmodifiable(_bookshelves);

  /// 所有书架条目
  List<BookshelfItem> get items => List.unmodifiable(_items);

  // ========== 预置书架 ID ==========
  static const presetReading = 'preset_reading'; // 正在读
  static const presetWant = 'preset_want'; // 想读
  static const presetFinished = 'preset_finished'; // 已读完
  static const presetDownloaded = 'preset_downloaded'; // 已下载的书
  static const presetLocal = 'preset_local'; // 本地图书（导入的本地文件，仅图书 tab 可见）

  /// 初始化：从本地加载，首次启动创建预置书架
  Future<void> init() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final shelfStr = prefs.getString(_kBookshelves);
      final itemStr = prefs.getString(_kItems);

      if (shelfStr != null) {
        final list = jsonDecode(shelfStr) as List;
        _bookshelves
          ..clear()
          ..addAll(
            list
                .map((s) => Bookshelf.fromJson(s as Map<String, dynamic>))
                .whereType<Bookshelf>(),
          );
      }

      if (itemStr != null) {
        final list = jsonDecode(itemStr) as List;
        _items
          ..clear()
          ..addAll(
            list
                .map((s) => BookshelfItem.fromJson(s as Map<String, dynamic>))
                .whereType<BookshelfItem>(),
          );
      }

      // 首次启动：创建预置书架
      if (_bookshelves.isEmpty) {
        _createPresetBookshelves();
        await _persistShelves();
      }

      _log('已加载 ${_bookshelves.length} 个书架，${_items.length} 条记录');
    } catch (e) {
      _log('加载书架失败: $e');
    }
    notifyListeners();
  }

  void _createPresetBookshelves() {
    final now = DateTime.now().millisecondsSinceEpoch;
    _bookshelves.addAll([
      Bookshelf(
        id: presetReading,
        name: '正在读',
        sortOrder: 0,
        isPreset: true,
        createdAt: now,
      ),
      Bookshelf(
        id: presetWant,
        name: '想读',
        sortOrder: 1,
        isPreset: true,
        createdAt: now,
      ),
      Bookshelf(
        id: presetFinished,
        name: '已读完',
        sortOrder: 2,
        isPreset: true,
        createdAt: now,
      ),
      Bookshelf(
        id: presetDownloaded,
        name: '已下载的书',
        sortOrder: 3,
        isPreset: true,
        createdAt: now,
      ),
    ]);
    _log('已创建 4 个预置书架');
  }

  // ========== 书架管理 ==========

  /// 新建自定义书架
  Future<Bookshelf?> createBookshelf(String name) async {
    final trimmed = name.trim();
    if (trimmed.isEmpty) return null;
    // 重名检查
    if (_bookshelves.any((s) => s.name == trimmed)) return null;

    final now = DateTime.now().millisecondsSinceEpoch;
    final maxOrder = _bookshelves.isEmpty
        ? -1
        : _bookshelves.map((s) => s.sortOrder).reduce((a, b) => a > b ? a : b);
    final shelf = Bookshelf(
      id: 'shelf_$now',
      name: trimmed,
      sortOrder: maxOrder + 1,
      isPreset: false,
      createdAt: now,
    );
    _bookshelves.add(shelf);
    _sortShelves();
    await _persistShelves();
    notifyListeners();
    _log('新建书架: $trimmed');
    return shelf;
  }

  /// 查找或创建"本地图书"书架（固定 id，导入本地图书专用；仅图书 tab 可见）。
  Future<Bookshelf> ensureLocalBookshelf() async {
    final idx = _bookshelves.indexWhere((s) => s.id == presetLocal);
    if (idx >= 0) return _bookshelves[idx];
    final now = DateTime.now().millisecondsSinceEpoch;
    final maxOrder = _bookshelves.isEmpty
        ? -1
        : _bookshelves.map((s) => s.sortOrder).reduce((a, b) => a > b ? a : b);
    final shelf = Bookshelf(
      id: presetLocal,
      name: '本地图书',
      sortOrder: maxOrder + 1,
      isPreset: true,
      createdAt: now,
    );
    _bookshelves.add(shelf);
    _sortShelves();
    await _persistShelves();
    notifyListeners();
    _log('新建本地图书书架');
    return shelf;
  }

  /// 重命名书架（预置书架也允许重命名）
  Future<bool> renameBookshelf(String id, String newName) async {
    final trimmed = newName.trim();
    if (trimmed.isEmpty) return false;
    final idx = _bookshelves.indexWhere((s) => s.id == id);
    if (idx < 0) return false;
    // 重名检查（排除自己）
    if (_bookshelves.any((s) => s.id != id && s.name == trimmed)) return false;

    _bookshelves[idx] = _bookshelves[idx].copyWith(name: trimmed);
    await _persistShelves();
    notifyListeners();
    _log('重命名书架: $trimmed');
    return true;
  }

  /// 删除书架（仅自定义书架可删）
  Future<bool> deleteBookshelf(String id) async {
    final idx = _bookshelves.indexWhere((s) => s.id == id);
    if (idx < 0) return false;
    if (_bookshelves[idx].isPreset) return false;

    final name = _bookshelves[idx].name;
    _bookshelves.removeAt(idx);
    // 同时移除该书架的所有条目
    _items.removeWhere((i) => i.bookshelfId == id);
    await _persistShelves();
    await _persistItems();
    notifyListeners();
    _log('删除书架: $name');
    return true;
  }

  // ========== 条目管理 ==========

  /// 添加到书架
  Future<void> addToBookshelf(
    String bookshelfId,
    String itemId,
    BookshelfItemType type, {
    String? meta,
  }) async {
    // 已存在则跳过
    if (_items.any(
      (i) =>
          i.bookshelfId == bookshelfId && i.itemId == itemId && i.type == type,
    )) {
      return;
    }
    _items.add(
      BookshelfItem(
        bookshelfId: bookshelfId,
        itemId: itemId,
        type: type,
        addedAt: DateTime.now().millisecondsSinceEpoch,
        meta: meta,
      ),
    );
    await _persistItems();
    notifyListeners();
    _log('加入书架 $bookshelfId: $itemId');
  }

  /// 批量确保条目在指定书架（幂等，一次性持久化）。
  /// 供下载服务启动时补加历史已下载到"已下载的书"书架。
  Future<void> ensureItemsInShelf(List<BookshelfItem> items) async {
    var changed = false;
    for (final it in items) {
      if (_items.any(
        (i) =>
            i.bookshelfId == it.bookshelfId &&
            i.itemId == it.itemId &&
            i.type == it.type,
      )) {
        continue;
      }
      _items.add(it);
      changed = true;
    }
    if (changed) {
      await _persistItems();
      notifyListeners();
    }
  }

  /// 批量添加到多个书架
  Future<void> addToBookshelves(
    List<String> bookshelfIds,
    String itemId,
    BookshelfItemType type,
  ) async {
    final now = DateTime.now().millisecondsSinceEpoch;
    var changed = false;
    for (final shelfId in bookshelfIds) {
      if (_items.any(
        (i) => i.bookshelfId == shelfId && i.itemId == itemId && i.type == type,
      )) {
        continue;
      }
      _items.add(
        BookshelfItem(
          bookshelfId: shelfId,
          itemId: itemId,
          type: type,
          addedAt: now,
        ),
      );
      changed = true;
    }
    if (changed) {
      await _persistItems();
      notifyListeners();
    }
  }

  /// 从书架移除
  Future<void> removeFromBookshelf(
    String bookshelfId,
    String itemId,
    BookshelfItemType type,
  ) async {
    final before = _items.length;
    _items.removeWhere(
      (i) =>
          i.bookshelfId == bookshelfId && i.itemId == itemId && i.type == type,
    );
    if (_items.length != before) {
      await _persistItems();
      notifyListeners();
      _log('从书架 $bookshelfId 移除: $itemId');
    }
  }

  /// 设置某本书的书架归属（先清空再添加，用于多选弹窗）
  /// [meta] 为 Book/Comic 的 JSON 快照，让书架页不依赖收藏夹即可展示与打开
  Future<void> setBookshelvesForItem(
    List<String> bookshelfIds,
    String itemId,
    BookshelfItemType type, {
    String? meta,
  }) async {
    _items.removeWhere((i) => i.itemId == itemId && i.type == type);
    final now = DateTime.now().millisecondsSinceEpoch;
    for (final shelfId in bookshelfIds) {
      _items.add(
        BookshelfItem(
          bookshelfId: shelfId,
          itemId: itemId,
          type: type,
          addedAt: now,
          meta: meta,
        ),
      );
    }
    await _persistItems();
    notifyListeners();
  }

  /// 获取某本书所在的所有书架 ID
  List<String> getBookshelvesForItem(String itemId, BookshelfItemType type) {
    return _items
        .where((i) => i.itemId == itemId && i.type == type)
        .map((i) => i.bookshelfId)
        .toList();
  }

  /// 判断某本书是否在某个书架中
  bool isInBookshelf(
    String bookshelfId,
    String itemId,
    BookshelfItemType type,
  ) {
    return _items.any(
      (i) =>
          i.bookshelfId == bookshelfId && i.itemId == itemId && i.type == type,
    );
  }

  /// 获取某书架中指定类型的条目ID列表（按添加时间倒序）
  List<String> getItemIdsInShelf(String bookshelfId, BookshelfItemType type) {
    final entries =
        _items
            .where((i) => i.bookshelfId == bookshelfId && i.type == type)
            .toList()
          ..sort((a, b) => b.addedAt.compareTo(a.addedAt));
    return entries.map((e) => e.itemId).toList();
  }

  /// 获取某书架中指定类型的条目（按添加时间倒序，含元数据快照）
  List<BookshelfItem> getItemsInShelf(
    String bookshelfId,
    BookshelfItemType type,
  ) {
    final entries =
        _items
            .where((i) => i.bookshelfId == bookshelfId && i.type == type)
            .toList()
          ..sort((a, b) => b.addedAt.compareTo(a.addedAt));
    return entries;
  }

  /// 获取某书架内的条目数量
  int countInShelf(String bookshelfId, [BookshelfItemType? type]) {
    if (type == null) {
      return _items.where((i) => i.bookshelfId == bookshelfId).length;
    }
    return _items
        .where((i) => i.bookshelfId == bookshelfId && i.type == type)
        .length;
  }

  /// 按阅读状态归位：加入 [toShelf]（正在读/已读完），移出另一状态书架与"想读"。
  /// 一旦开始/读完阅读即不再"想读"，故"想读"随之移出；
  /// 源书架（已下载的书/本地图书/自建）不动；仅在变化时一次 notify。
  Future<void> moveBetweenStatusShelves({
    required String bookId,
    required BookshelfItemType type,
    required String toShelf,
    String? meta,
  }) async {
    final fromShelf = toShelf == presetReading ? presetFinished : presetReading;
    var changed = false;
    if (!_items.any(
      (i) => i.bookshelfId == toShelf && i.itemId == bookId && i.type == type,
    )) {
      _items.add(
        BookshelfItem(
          bookshelfId: toShelf,
          itemId: bookId,
          type: type,
          addedAt: DateTime.now().millisecondsSinceEpoch,
          meta: meta,
        ),
      );
      changed = true;
    }
    final before = _items.length;
    _items.removeWhere(
      (i) =>
          (i.bookshelfId == fromShelf || i.bookshelfId == presetWant) &&
          i.itemId == bookId &&
          i.type == type,
    );
    if (_items.length != before) changed = true;
    if (changed) {
      await _persistItems();
      notifyListeners();
    }
  }

  /// 取某条目已有的 Book 快照 meta（任意书架中第一个非空 meta）。
  String? findItemMeta(String itemId, BookshelfItemType type) {
    for (final i in _items) {
      if (i.itemId == itemId && i.type == type && i.meta != null) {
        return i.meta;
      }
    }
    return null;
  }

  /// 更新某条目在各书架的 meta 快照（详情页回填 totalChapters/author 用）。
  /// 与收藏解耦后，书架显示/点击完整度判断完全依赖此快照。
  Future<void> updateItemMeta(
    String itemId,
    BookshelfItemType type,
    String meta,
  ) async {
    var changed = false;
    for (var i = 0; i < _items.length; i++) {
      final it = _items[i];
      if (it.itemId == itemId && it.type == type && it.meta != meta) {
        _items[i] = BookshelfItem(
          bookshelfId: it.bookshelfId,
          itemId: it.itemId,
          type: it.type,
          addedAt: it.addedAt,
          meta: meta,
        );
        changed = true;
      }
    }
    if (changed) {
      await _persistItems();
      notifyListeners();
    }
  }

  // ========== 内部方法 ==========

  void _sortShelves() {
    _bookshelves.sort((a, b) => a.sortOrder.compareTo(b.sortOrder));
  }

  Future<void> _persistShelves() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final list = _bookshelves.map((s) => s.toJson()).toList();
      await prefs.setString(_kBookshelves, jsonEncode(list));
    } catch (e) {
      _log('保存书架失败: $e');
    }
  }

  Future<void> _persistItems() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final list = _items.map((i) => i.toJson()).toList();
      await prefs.setString(_kItems, jsonEncode(list));
    } catch (e) {
      _log('保存书架条目失败: $e');
    }
  }
}
