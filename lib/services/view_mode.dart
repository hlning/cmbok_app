import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 视图模式共享状态（网格 / 列表），搜索页和收藏页共用
class ViewMode extends ChangeNotifier {
  ViewMode._();
  static final ViewMode _instance = ViewMode._();
  factory ViewMode() => _instance;

  static const _key = 'comic_view_mode';

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
