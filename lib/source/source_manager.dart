import 'package:flutter/foundation.dart';
import '../services/settings_service.dart';
import 'config_manga_source.dart';
import 'copy_manga_source.dart';
import 'manga_source.dart';
import 'manhuaren_config.dart';
import 'manhuaren_source.dart';
import 'site_config.dart';
import 'source_config_store.dart';
import 'source_definition.dart';
import 'zaimanhua_config.dart';
import 'zaimanhua_source.dart';

void _log(String message) {
  if (kDebugMode) {
    debugPrint('[SourceManager] $message');
  }
}

/// 封面/列表缩略图加载头（防盗链/UA）。
/// 传 [sourceId] 用漫画所属源的头（多源书架/收藏封面防盗链）；不传则取当前源。
/// 非防盗链源（如 copymanga）带上也无害；防盗链源（如 mycomic 的 biccam）需 Referer。
Map<String, String> coverHeaders([String? sourceId]) {
  final s = (sourceId != null && sourceId.isNotEmpty)
      ? (SourceManager().getSource(sourceId) ?? SourceManager().current)
      : SourceManager().current;
  return {...s.imageHeaders, if (s.referer != null) 'Referer': s.referer!};
}

/// 漫画源管理器（单例 ChangeNotifier）。
///
/// 注册各源（内置代码源 + 配置源），维护「当前源」，供 UI/下载/阅读统一调用。
/// 阶段1仅注册内置 CopyMangaSource；阶段2起追加 ConfigDrivenSource（配置源）等。
class SourceManager extends ChangeNotifier {
  SourceManager._();
  static final SourceManager _instance = SourceManager._();
  factory SourceManager() => _instance;

  final Map<String, MangaSource> _sources = {};
  MangaSource? _current;
  bool _initialized = false;

  /// 当前源（未初始化时抛错，确保 init() 先于使用）
  MangaSource get current {
    final c = _current;
    if (c == null) {
      throw StateError('SourceManager 未初始化，请先调用 init()');
    }
    return c;
  }

  /// 所有已注册源
  List<MangaSource> get sources => _sources.values.toList();

  /// 初始化：注册 copymanga 代码源 + 从 SourceConfigStore 加载配置源/api 源，恢复当前源选择
  Future<void> init() async {
    if (_initialized) return;
    // copymanga：代码源（阶段2起配置化，当前仍内置注册）
    _register(CopyMangaSource());
    // 配置源 + api 源（zaimanhua）：从 SourceConfigStore 加载
    // （文档目录 sources.json > assets/config/sources.json > 代码常量兜底）
    final defs = await SourceConfigStore().loadLocal();
    for (final def in defs) {
      final src = _instantiate(def);
      if (src != null) {
        // 注入源级元数据（needsMagic）
        src.needsMagic = def.needsMagic;
        _register(src);
      }
    }

    // 禁用源列表（持久化，与 sources.json 解耦）
    _disabledIds = SettingsService().disabledSourceIds.toSet();

    // 恢复当前源：已保存 id 优先（且未禁用），否则取首个启用源
    final savedId = SettingsService().currentSourceId;
    _current = (_sources[savedId] != null && !_disabledIds.contains(savedId))
        ? _sources[savedId]!
        : (enabledSources.isNotEmpty
              ? enabledSources.first
              : _sources.values.first);
    _initialized = true;
    _log('初始化完成，源数: ${_sources.length}，当前源: ${_current!.id}');
    notifyListeners();
  }

  /// 重新加载源配置（云端更新 / 恢复本地默认后调用）。
  Future<void> reload() async {
    _sources.clear();
    _current = null;
    _initialized = false;
    await init();
  }

  /// 按 SourceDefinition 的 type/engine 实例化对应 Source；未知类型返回 null（跳过，不崩）。
  MangaSource? _instantiate(SourceDefinition def) {
    switch (def.type) {
      case 'config':
        return ConfigMangaSource(SiteConfig.fromJson(def.config));
      case 'api':
        switch (def.engine) {
          case 'zaimanhua':
            return ZaimanhuaSource(ZaimanhuaConfig.fromJson(def.config));
          case 'manhuaren':
            return ManhuarenSource(ManhuarenConfig.fromJson(def.config));
          // case 'copymanga': 阶段2配置化后启用
          default:
            _log('未知 api engine，跳过: ${def.engine} (id=${def.id})');
            return null;
        }
      default:
        _log('未知 source type，跳过: ${def.type} (id=${def.id})');
        return null;
    }
  }

  void _register(MangaSource source) {
    _sources[source.id] = source;
  }

  /// 切换当前源
  void setCurrent(MangaSource source) {
    if (_current?.id == source.id) return;
    if (!_sources.containsKey(source.id)) {
      _register(source);
    }
    _current = _sources[source.id]!;
    SettingsService().setCurrentSourceId(source.id);
    _log('切换当前源: ${source.id}');
    notifyListeners();
  }

  /// 按 id 取源
  MangaSource? getSource(String id) => _sources[id];

  // === 启用/禁用 ===
  Set<String> _disabledIds = {};

  /// 启用源列表（搜索页只展示这些）。
  List<MangaSource> get enabledSources =>
      sources.where((s) => !_disabledIds.contains(s.id)).toList();

  /// 源是否启用。
  bool isEnabled(String id) => !_disabledIds.contains(id);

  /// 设置源启用/禁用（持久化 + notify）。
  /// 禁用当前源时自动切到首个启用源；全部禁用时回退保留当前，避免无可用源。
  Future<void> setEnabled(String id, bool enabled) async {
    final changed = enabled ? _disabledIds.remove(id) : _disabledIds.add(id);
    if (!changed) return;
    await SettingsService().setDisabledSourceIds(_disabledIds.toList());
    if (!enabled && _current?.id == id) {
      final next = enabledSources.isNotEmpty ? enabledSources.first : null;
      if (next != null) {
        _current = next;
        await SettingsService().setCurrentSourceId(next.id);
        _log('禁用当前源 $id，自动切换到 ${next.id}');
      } else {
        // 无其他启用源：回退，保留当前源可用
        _disabledIds.remove(id);
        await SettingsService().setDisabledSourceIds(_disabledIds.toList());
        _log('禁用 $id 会导致无可用源，已回退');
      }
    }
    _log('源 $id ${enabled ? "启用" : "禁用"}');
    notifyListeners();
  }
}
