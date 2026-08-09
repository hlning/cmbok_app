import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 搜索历史服务（本地持久化关键词列表，按 key 分组）
/// 使用内存缓存：即使磁盘写入失败，UI 也能即时更新。
/// 漫画搜索用默认 key，图书搜索传 key='book_search_history'，互不影响。
class SearchHistoryService {
  static const _defaultKey = 'search_history';
  static const _max = 20;

  /// key -> 关键词缓存
  static final Map<String, List<String>> _caches = {};

  static Future<List<String>> load({String key = _defaultKey}) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      _caches[key] = prefs.getStringList(key) ?? [];
    } catch (e) {
      if (kDebugMode) print('[SearchHistory] load 失败: $e');
    }
    return List<String>.of(_caches[key] ?? const []);
  }

  /// 添加一条搜索记录（去重、置顶、限量）
  static Future<List<String>> add(
    String keyword, {
    String key = _defaultKey,
  }) async {
    final kw = keyword.trim();
    final cache = _caches.putIfAbsent(key, () => <String>[]);
    if (kw.isEmpty) return List<String>.of(cache);
    _caches[key] = cache.where((e) => e != kw).toList()..insert(0, kw);
    if (_caches[key]!.length > _max)
      _caches[key] = _caches[key]!.sublist(0, _max);
    await _persist(key);
    return List<String>.of(_caches[key]!);
  }

  static Future<List<String>> remove(
    String keyword, {
    String key = _defaultKey,
  }) async {
    final cache = _caches.putIfAbsent(key, () => <String>[]);
    _caches[key] = cache.where((e) => e != keyword).toList();
    await _persist(key);
    return List<String>.of(_caches[key]!);
  }

  static Future<List<String>> clear({String key = _defaultKey}) async {
    _caches[key] = [];
    await _persist(key);
    return List<String>.of(_caches[key]!);
  }

  static Future<void> _persist(String key) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setStringList(key, _caches[key] ?? []);
    } catch (e) {
      if (kDebugMode) print('[SearchHistory] persist 失败: $e');
    }
  }
}
