// 漫画源配置存储（独立通道，单例）。
//
// 负责 SourceDefinition 的本地加载与持久化、远端拉取。软件不自带任何漫画源，
// 源定义完全云端驱动：仅从文档目录 sources.json（fetchRemote 写入的云端缓存）加载，
// 无缓存时返回空列表，由上层 UI（搜索页空状态）提示用户填云端地址并更新。
//
// fetchRemote 读用户配置的云端 URL（SettingsService.sourceRepoUrl）：为空返回 null（不拉取，
// 沿用本地）；非空则 Dio 拉取 sources.json -> 校验 -> saveLocal -> 返回新 defs。
// 风格参考 RemoteConfigService（Dio + 本地缓存）但与之解耦，独立演进。

import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../services/settings_service.dart';
import 'source_definition.dart';

void _log(String message) {
  if (kDebugMode) {
    debugPrint('[SourceConfigStore] $message');
  }
}

const _kDocFileName = 'sources.json';
// 云端源迁移标记：升级到本版本时一次性清除本地源覆盖层（旧版本缓存/自定义）。
const _kCloudOnlyMigrationDone = 'source_cloud_only_migration_done';

class SourceConfigStore {
  SourceConfigStore._();
  static final SourceConfigStore _instance = SourceConfigStore._();
  factory SourceConfigStore() => _instance;

  /// 升级到本版本的一次性迁移：清除文档目录 sources.json 覆盖层。
  ///
  /// 旧版本可能在本地下沉了过时/自定义的源配置；本版本起源定义完全云端驱动，
  /// 升级首跑清掉本地覆盖层（无自带源兜底），之后仅靠 fetchRemote 更新。
  /// 用 SharedPreferences 标记保证仅执行一次（失败不置位，下次重试）。
  Future<void> _migrateOnceIfNeeded() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      if (prefs.getBool(_kCloudOnlyMigrationDone) ?? false) return;
      await resetToLocal();
      await prefs.setBool(_kCloudOnlyMigrationDone, true);
      _log('已执行云端源迁移：清除本地源覆盖层');
    } catch (e) {
      _log('云端源迁移失败（下次重试）: $e');
    }
  }

  /// 加载源配置定义：仅读文档目录 sources.json（fetchRemote 写入的云端缓存）。
  /// 软件不自带源，无缓存时返回空列表，由上层 UI 提示无可用源。
  Future<List<SourceDefinition>> loadLocal() async {
    // 升级一次性迁移：先清掉旧版本本地源覆盖层（仅一次）。
    await _migrateOnceIfNeeded();
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
      _log('文档目录配置读取失败: $e');
    }

    _log('无本地源配置（未从云端更新过）');
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

  /// 删除文档目录覆盖层（清空云端缓存，回到无源状态）。
  ///
  /// 供 [_migrateOnceIfNeeded] 升级迁移调用；软件不自带源，清空后无源直至下次云端更新。
  Future<void> resetToLocal() async {
    try {
      final dir = await getApplicationDocumentsDirectory();
      final file = File('${dir.path}/$_kDocFileName');
      if (await file.exists()) await file.delete();
      _log('已清除文档目录覆盖层（无源直至云端更新）');
    } catch (e) {
      _log('清除文档目录覆盖层失败: $e');
    }
  }

  /// 远端拉取 sources.json。
  ///
  /// 读用户配置的云端 URL（[SettingsService.sourceRepoUrl]）：为空返回 null（不拉取，沿用本地）。
  /// 非空则 Dio GET -> 容错解析为 SourceConfigFile -> 空则返回 null -> 否则 saveLocal 并返回 defs。
  /// 失败返回 null（保留本地），不抛错给上层（启动后台调用）。
  Future<List<SourceDefinition>?> fetchRemote() async {
    final url = SettingsService().sourceRepoUrl.trim();
    if (url.isEmpty) {
      _log('未配置云端仓库地址，跳过远端拉取');
      return null;
    }
    try {
      final dio = Dio(
        BaseOptions(
          connectTimeout: const Duration(seconds: 10),
          receiveTimeout: const Duration(seconds: 15),
          responseType: ResponseType.json,
        ),
      );
      final res = await dio.get<dynamic>(url);
      final cfg = _asMap(res.data);
      if (cfg == null) {
        _log('云端 sources.json 解析失败（非 JSON Map）: $url');
        return null;
      }
      final parsed = SourceConfigFile.fromJson(cfg);
      if (parsed.sources.isEmpty) {
        _log('云端 sources.json 为空，忽略');
        return null;
      }
      await saveLocal(parsed.sources);
      _log('已从云端拉取并保存: ${parsed.sources.length} 源');
      return parsed.sources;
    } catch (e) {
      _log('云端 sources.json 拉取失败（保留本地）: $e');
      return null;
    }
  }

  /// 容错解析为 Map：Dio 默认按 application/json 自动解析为 Map，
  /// 个别情况下返回 String，则再 jsonDecode。
  static Map<String, dynamic>? _asMap(dynamic data) {
    if (data is Map) return Map<String, dynamic>.from(data);
    if (data is String && data.isNotEmpty) {
      try {
        final d = jsonDecode(data);
        if (d is Map) return Map<String, dynamic>.from(d);
      } catch (_) {}
    }
    return null;
  }
}
