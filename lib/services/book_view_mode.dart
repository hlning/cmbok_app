import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 图书视图模式共享状态（网格 / 列表），图书搜索页和图书收藏页共用，
/// 独立于漫画 ViewMode，互不影响。
class BookViewMode extends ChangeNotifier {
  BookViewMode._();
  static final BookViewMode _instance = BookViewMode._();
  factory BookViewMode() => _instance;

  static const _key = 'book_view_mode';

  bool _isGrid = true;
  bool get isGrid => _isGrid;

  /// 初始化：从本地加载视图偏好（默认网格）
  Future<void> init() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      _isGrid = prefs.getBool(_key) ?? true;
    } catch (_) {}
    notifyListeners();
  }

  void set(bool isGrid) {
    if (_isGrid == isGrid) return;
    _isGrid = isGrid;
    notifyListeners();
    _persist();
  }

  Future<void> _persist() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(_key, _isGrid);
    } catch (_) {}
  }
}
