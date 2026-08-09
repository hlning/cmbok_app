import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/book.dart';

/// 图书收藏服务（本地持久化 via SharedPreferences）
/// 单例 + ChangeNotifier，UI 用 ListenableBuilder 监听变化。
/// 对应漫画 FavoritesService，独立存储图书收藏。
class BookFavoritesService extends ChangeNotifier {
  BookFavoritesService._();
  static final BookFavoritesService _instance = BookFavoritesService._();
  factory BookFavoritesService() => _instance;

  static const _key = 'book_favorites';

  final List<Book> _books = [];
  List<Book> get books => List.unmodifiable(_books);

  /// 初始化：从本地加载已收藏图书
  Future<void> init() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final list = prefs.getStringList(_key) ?? [];
      _books
        ..clear()
        ..addAll(
          list.map((s) {
            try {
              return Book.fromJson(jsonDecode(s) as Map<String, dynamic>);
            } catch (_) {
              return null;
            }
          }).whereType<Book>(),
        );
      _log('已加载 ${_books.length} 本收藏图书');
    } catch (e) {
      _log('加载图书收藏失败: $e');
    }
    notifyListeners();
  }

  bool isFavorite(String id) => _books.any((b) => b.id == id);

  /// 切换收藏状态
  Future<void> toggle(Book book) async {
    if (isFavorite(book.id)) {
      _books.removeWhere((b) => b.id == book.id);
      _log('取消收藏: ${book.title}');
    } else {
      _books.insert(0, book);
      _log('添加收藏: ${book.title}');
    }
    await _persist();
    notifyListeners();
  }

  /// 批量取消收藏（按 id 集合，一次持久化 + 一次通知）
  Future<void> removeMany(Iterable<String> ids) async {
    if (ids.isEmpty) return;
    final idSet = ids.toSet();
    _books.removeWhere((b) => idSet.contains(b.id));
    _log('批量取消收藏: ${idSet.length} 本');
    await _persist();
    notifyListeners();
  }

  Future<void> _persist() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final list = _books.map((b) => jsonEncode(b.toJson())).toList();
      await prefs.setStringList(_key, list);
    } catch (e) {
      _log('保存图书收藏失败: $e');
    }
  }

  void _log(String msg) {
    if (kDebugMode) debugPrint('[BookFavorites] $msg');
  }
}
