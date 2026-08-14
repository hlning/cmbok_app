import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/trim_preset.dart';

/// 去白边预设管理服务
///
/// 单例 + ChangeNotifier，持久化到 SharedPreferences。
class TrimPresetService extends ChangeNotifier {
  static final TrimPresetService _instance = TrimPresetService._internal();
  factory TrimPresetService() => _instance;
  TrimPresetService._internal();

  static const String _presetsKey = 'trim_whitespace_presets';

  List<TrimPreset> _presets = [];

  List<TrimPreset> get presets => List.unmodifiable(_presets);

  bool _inited = false;
  bool get inited => _inited;

  /// 初始化（从 SharedPreferences 加载）
  Future<void> init() async {
    if (_inited) return;
    try {
      final prefs = await SharedPreferences.getInstance();
      final jsonStr = prefs.getString(_presetsKey);
      if (jsonStr != null && jsonStr.isNotEmpty) {
        final List<dynamic> list = jsonDecode(jsonStr);
        _presets = list
            .map((e) => TrimPreset.fromJson(e as Map<String, dynamic>))
            .toList();
      }
    } catch (e) {
      if (kDebugMode) {
        debugPrint('[TrimPresetService] 加载预设失败: $e');
      }
      _presets = [];
    }
    _inited = true;
  }

  /// 新增预设（名称唯一，重名返回 false）
  Future<bool> addPreset(TrimPreset preset) async {
    if (_presets.any((p) => p.name == preset.name)) {
      return false; // 重名
    }
    _presets.add(preset);
    notifyListeners();
    await _save();
    return true;
  }

  /// 删除预设
  Future<void> deletePreset(String name) async {
    _presets.removeWhere((p) => p.name == name);
    notifyListeners();
    await _save();
  }

  /// 按名称获取预设
  TrimPreset? getByName(String name) {
    for (final p in _presets) {
      if (p.name == name) return p;
    }
    return null;
  }

  Future<void> _save() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final jsonStr =
          jsonEncode(_presets.map((p) => p.toJson()).toList());
      await prefs.setString(_presetsKey, jsonStr);
    } catch (e) {
      if (kDebugMode) {
        debugPrint('[TrimPresetService] 保存预设失败: $e');
      }
    }
  }
}
