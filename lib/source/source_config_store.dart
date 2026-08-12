// 漫画源配置存储（独立通道，单例）。
//
// 负责 SourceDefinition 的本地加载与持久化、远端拉取（预留）。两层兜底：
//   1. 文档目录 sources.json（远端更新/自定义覆盖层，可写）
//   2. assets/config/sources.json（随包发布的出厂默认，只读）
// 两层均失败时返回空列表，由上层 UI 提示无可用源。
//
// 远端 fetchRemote 本期为 stub（云端 URL 待定）；上传云端后实现 Dio 拉取 -> saveLocal。
// 风格参考 RemoteConfigService（Dio + 本地缓存）但与之解耦，独立演进。

import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:path_provider/path_provider.dart';

import 'source_definition.dart';

void _log(String message) {
  if (kDebugMode) {
    debugPrint('[SourceConfigStore] $message');
  }
}

const _kAssetPath = 'assets/config/sources.json';
const _kDocFileName = 'sources.json';

class SourceConfigStore {
  SourceConfigStore._();
  static final SourceConfigStore _instance = SourceConfigStore._();
  factory SourceConfigStore() => _instance;

  /// 两层兜底加载源配置定义。
  Future<List<SourceDefinition>> loadLocal() async {
    // 1. 文档目录（远端更新 / 自定义覆盖层）
    try {
      final dir = await getApplicationDocumentsDirectory();
      final file = File('${dir.path}/$_kDocFileName');
      if (await file.exists()) {
        final raw = await file.readAsString();
        final parsed = SourceConfigFile.fromJson(
          jsonDecode(raw) as Map<String, dynamic>,
        );
        if (parsed.sources.isNotEmpty) {
          _log('加载文档目录配置: ${parsed.sources.length} 源');
          return parsed.sources;
        }
      }
    } catch (e) {
      _log('文档目录配置读取失败，回退 assets: $e');
    }

    // 2. assets（出厂默认）
    try {
      final raw = await rootBundle.loadString(_kAssetPath);
      final parsed = SourceConfigFile.fromJson(
        jsonDecode(raw) as Map<String, dynamic>,
      );
      if (parsed.sources.isNotEmpty) {
        _log('加载 assets 配置: ${parsed.sources.length} 源');
        return parsed.sources;
      }
    } catch (e) {
      _log('assets 配置读取失败: $e');
    }

    // 两层均失败：返回空，由上层 UI 提示无可用源
    _log('配置加载失败：文档目录与 assets 均无可用源');
    return [];
  }

  /// 写入文档目录（远端更新或自定义后调用）。
  Future<void> saveLocal(List<SourceDefinition> defs) async {
    final dir = await getApplicationDocumentsDirectory();
    final file = File('${dir.path}/$_kDocFileName');
    final fileObj = SourceConfigFile(version: 1, sources: defs);
    await file.writeAsString(jsonEncode(fileObj.toJson()));
    _log('已写入文档目录配置: ${defs.length} 源');
  }

  /// 删除文档目录覆盖层，回退到 assets 出厂默认（调用后需 SourceManager.reload()）。
  Future<void> resetToLocal() async {
    try {
      final dir = await getApplicationDocumentsDirectory();
      final file = File('${dir.path}/$_kDocFileName');
      if (await file.exists()) await file.delete();
      _log('已清除文档目录覆盖层，回退 assets 默认');
    } catch (e) {
      _log('清除文档目录覆盖层失败: $e');
    }
  }

  /// 远端拉取（本期 stub：云端 URL 待定，返回 null 表示无更新）。
  ///
  /// 上传云端后实现：Dio 拉 sources.json -> 校验 -> saveLocal -> 返回新 defs。
  Future<List<SourceDefinition>?> fetchRemote() async {
    // TODO(远端): 云端 URL 定后，Dio 拉取 sources.json -> 校验 -> saveLocal -> 返回。
    return null;
  }
}
