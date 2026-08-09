import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/comic.dart';

/// 收藏服务（本地持久化 via SharedPreferences）
/// 单例 + ChangeNotifier，UI 用 ListenableBuilder 监听变化。
class FavoritesService extends ChangeNotifier {
  FavoritesService._();
  static final FavoritesService _instance = FavoritesService._();
  factory FavoritesService() => _instance;

  static const _comicKey = 'comic_favorites';

  final List<Comic> _comics = [];
  List<Comic> get comics => List.unmodifiable(_comics);

  /// 初始化：从本地加载已收藏漫画
  Future<void> init() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final list = prefs.getStringList(_comicKey) ?? [];
      _comics
        ..clear()
        ..addAll(
          list.map((s) {
            try {
              return Comic.fromJson(jsonDecode(s) as Map<String, dynamic>);
            } catch (_) {
              return null;
            }
          }).whereType<Comic>(),
        );
      _log('已加载 ${_comics.length} 本收藏漫画');
    } catch (e) {
      _log('加载收藏失败: $e');
    }
    notifyListeners();
  }

  bool isFavorite(String id) => _comics.any((c) => c.id == id);

  /// 切换收藏状态
  Future<void> toggle(Comic comic) async {
    if (isFavorite(comic.id)) {
      _comics.removeWhere((c) => c.id == comic.id);
      _log('取消收藏: ${comic.title}');
    } else {
      _comics.insert(0, comic);
      _log('添加收藏: ${comic.title}');
    }
    await _persist();
    notifyListeners();
  }

  /// 批量取消收藏（按 id 集合，一次持久化 + 一次通知）
  Future<void> removeMany(Iterable<String> ids) async {
    if (ids.isEmpty) return;
    final idSet = ids.toSet();
    _comics.removeWhere((c) => idSet.contains(c.id));
    _log('批量取消收藏: ${idSet.length} 本');
    await _persist();
    notifyListeners();
  }

  Future<void> _persist() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final list = _comics.map((c) => jsonEncode(c.toJson())).toList();
      await prefs.setStringList(_comicKey, list);
    } catch (e) {
      _log('保存收藏失败: $e');
    }
  }

  void _log(String msg) {
    if (kDebugMode) print('[Favorites] $msg');
  }
}
