import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/book.dart';
import '../models/comic.dart';

/// 浏览记录服务（本地持久化 via SharedPreferences）
/// 单例 + ChangeNotifier，UI 用 ListenableBuilder 监听变化。
/// 只记录从漫画/图书搜索页进入详情的记录；重复进入仅更新时间并置顶，限量保留。
class BrowseHistoryService extends ChangeNotifier {
  BrowseHistoryService._();
  static final BrowseHistoryService _instance = BrowseHistoryService._();
  factory BrowseHistoryService() => _instance;

  static const _comicKey = 'browse_comic_history';
  static const _bookKey = 'browse_book_history';
  static const _max = 50;

  final List<_Record<Comic>> _comics = [];
  final List<_Record<Book>> _books = [];

  /// 漫画浏览记录（按时间倒序）
  List<Comic> get comics => List.unmodifiable(_comics.map((r) => r.item));

  /// 图书浏览记录（按时间倒序）
  List<Book> get books => List.unmodifiable(_books.map((r) => r.item));

  /// 初始化：从本地加载浏览记录
  Future<void> init() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      _comics
        ..clear()
        ..addAll(_loadComics(prefs.getStringList(_comicKey) ?? []));
      _books
        ..clear()
        ..addAll(_loadBooks(prefs.getStringList(_bookKey) ?? []));
      _log('已加载 ${_comics.length} 条漫画、${_books.length} 条图书浏览记录');
    } catch (e) {
      _log('加载浏览记录失败: $e');
    }
    notifyListeners();
  }

  /// 记录一条漫画浏览（去重置顶、更新时间、限量）
  Future<void> recordComic(Comic comic) async {
    final key = _comicKeyOf(comic);
    if (key.isEmpty) return;
    _comics.removeWhere((r) => _comicKeyOf(r.item) == key);
    _comics.insert(0, _Record(comic, DateTime.now().millisecondsSinceEpoch));
    if (_comics.length > _max) {
      _comics.removeRange(_max, _comics.length);
    }
    await _persist();
    notifyListeners();
  }

  /// 记录一条图书浏览（去重置顶、更新时间、限量）
  Future<void> recordBook(Book book) async {
    final key = _bookKeyOf(book);
    if (key.isEmpty) return;
    _books.removeWhere((r) => _bookKeyOf(r.item) == key);
    _books.insert(0, _Record(book, DateTime.now().millisecondsSinceEpoch));
    if (_books.length > _max) {
      _books.removeRange(_max, _books.length);
    }
    await _persist();
    notifyListeners();
  }

  /// 清理漫画记录：beforeTs 为空清全部，否则清时间戳早于 beforeTs 的
  Future<void> clearComics({int? beforeTs}) async {
    final before = _comics.length;
    if (beforeTs == null) {
      _comics.clear();
    } else {
      _comics.removeWhere((r) => r.ts < beforeTs);
    }
    if (_comics.length == before) return;
    _log('清理漫画浏览记录: ${before - _comics.length} 条');
    await _persist();
    notifyListeners();
  }

  /// 清理图书记录：beforeTs 为空清全部，否则清时间戳早于 beforeTs 的
  Future<void> clearBooks({int? beforeTs}) async {
    final before = _books.length;
    if (beforeTs == null) {
      _books.clear();
    } else {
      _books.removeWhere((r) => r.ts < beforeTs);
    }
    if (_books.length == before) return;
    _log('清理图书浏览记录: ${before - _books.length} 条');
    await _persist();
    notifyListeners();
  }

  Future<void> _persist() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setStringList(
        _comicKey,
        _comics
            .map((r) => jsonEncode({'data': r.item.toJson(), 'ts': r.ts}))
            .toList(),
      );
      await prefs.setStringList(
        _bookKey,
        _books
            .map((r) => jsonEncode({'data': r.item.toJson(), 'ts': r.ts}))
            .toList(),
      );
    } catch (e) {
      _log('保存浏览记录失败: $e');
    }
  }

  List<_Record<Comic>> _loadComics(List<String> list) {
    final out = <_Record<Comic>>[];
    for (final s in list) {
      try {
        final m = jsonDecode(s) as Map<String, dynamic>;
        final comic = Comic.fromJson(
          (m['data'] as Map<String, dynamic>?) ?? const {},
        );
        final ts = (m['ts'] as num?)?.toInt() ?? 0;
        out.add(_Record(comic, ts));
      } catch (_) {}
    }
    return out;
  }

  List<_Record<Book>> _loadBooks(List<String> list) {
    final out = <_Record<Book>>[];
    for (final s in list) {
      try {
        final m = jsonDecode(s) as Map<String, dynamic>;
        final book = Book.fromJson(
          (m['data'] as Map<String, dynamic>?) ?? const {},
        );
        final ts = (m['ts'] as num?)?.toInt() ?? 0;
        out.add(_Record(book, ts));
      } catch (_) {}
    }
    return out;
  }

  // 去重 key：漫画优先 pathWord（搜索结果 id 即 pathWord），其次 id
  String _comicKeyOf(Comic c) =>
      c.pathWord.isNotEmpty ? c.pathWord : c.id;

  // 去重 key：图书优先 hash（eapi hash 稳定），其次 id
  String _bookKeyOf(Book b) => b.hash.isNotEmpty ? b.hash : b.id;

  void _log(String msg) {
    if (kDebugMode) print('[BrowseHistory] $msg');
  }
}

/// 内部记录：数据项 + 浏览时间戳
class _Record<T> {
  final T item;
  final int ts;
  _Record(this.item, this.ts);
}
