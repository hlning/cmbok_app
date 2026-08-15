import 'package:flutter/foundation.dart';
import '../services/settings_service.dart';
import 'config_manga_source.dart';
import 'copy_manga_source.dart';
import 'copymanga_config.dart';
import 'manga_source.dart';
import 'manhuaren_config.dart';
import 'manhuaren_source.dart';
import 'models.dart';
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
/// 注册各源（配置源 + api 源），维护「当前源」，供 UI/下载/阅读统一调用。
/// 软件不自带任何漫画源，源定义完全云端驱动（仅文档目录 sources.json 云端缓存）；
/// 无源时 [current] 返回 [_NoSource] 哨兵不崩，由搜索页空状态引导用户填云端地址。
/// init 末尾非阻塞后台拉取云端 sources.json（用户已填云端地址时），有变化才 reload。
class SourceManager extends ChangeNotifier {
  SourceManager._();
  static final SourceManager _instance = SourceManager._();
  factory SourceManager() => _instance;

  final Map<String, MangaSource> _sources = {};
  MangaSource? _current;
  bool _initialized = false;
  // 零源时的哨兵源：current 返回它而非抛异常，避免各处 .current 在无源时崩溃。
  // 搜索/分类返回空；详情/章节/取图抛描述性错误，被调用方现有 try/catch 接住提示用户。
  final MangaSource _noSource = _NoSource();

  /// 当前源。零源时返回 [_noSource] 哨兵（不抛异常），保证 UI/封面头等各处不崩。
  MangaSource get current => _current ?? _noSource;

  /// 所有已注册源
  List<MangaSource> get sources => _sources.values.toList();

  /// 初始化：从 SourceConfigStore 加载云端缓存的源（配置源 + api 源），恢复当前源选择。
  ///
  /// 软件不自带源，仅从文档目录 sources.json（云端缓存）加载；无缓存则零源，
  /// current 返回 [_NoSource] 哨兵，由搜索页空状态引导用户填云端地址并更新。
  /// [fetchCloud]=true 时（仅首次 init），末尾非阻塞后台拉取云端 sources.json，有变化才 reload；
  /// reload 触发的 init 传 false，避免循环拉取。
  Future<void> init({bool fetchCloud = true}) async {
    if (_initialized) return;
    // 配置源 + api 源（copymanga/zaimanhua/manhuaren）：从 SourceConfigStore 加载
    // （文档目录 sources.json 云端缓存 > 空列表）
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
              : (_sources.values.isNotEmpty ? _sources.values.first : null));
    _initialized = true;
    _log('初始化完成，源数: ${_sources.length}，当前源: ${_current?.id}');
    notifyListeners();

    // 仅首次 init 触发云端拉取（reload 传 fetchCloud:false 跳过，避免循环）。
    if (fetchCloud) _refreshFromCloud();
  }

  /// 重新加载源配置（云端更新 / 恢复本地默认后调用）。
  Future<void> reload() async {
    _sources.clear();
    _current = null;
    _initialized = false;
    await init(fetchCloud: false);
  }

  /// 启动后台拉取云端 sources.json（非阻塞）。
  ///
  /// 用户未填云端地址（sourceRepoUrl 为空）时跳过，沿用本地配置。
  /// 拉到且非空时 saveLocal 并 reload（reload 不再触发云端拉取，按 savedId 恢复当前源）。
  /// 失败静默保留本地，不阻塞启动。
  Future<void> _refreshFromCloud() async {
    try {
      final remote = await SourceConfigStore().fetchRemote();
      if (remote == null || remote.isEmpty) return;
      await reload();
      _log('已从云端更新源: ${remote.length} 个');
    } catch (e) {
      _log('云端源拉取失败（保留本地）: $e');
    }
  }

  /// 按 SourceDefinition 的 type/engine 实例化对应 Source；未知类型返回 null（跳过，不崩）。
  MangaSource? _instantiate(SourceDefinition def) {
    switch (def.type) {
      case 'config':
        return ConfigMangaSource(SiteConfig.fromJson(def.config));
      case 'api':
        switch (def.engine) {
          case 'copymanga':
            return CopyMangaSource(CopymangaConfig.fromJson(def.config));
          case 'zaimanhua':
            return ZaimanhuaSource(ZaimanhuaConfig.fromJson(def.config));
          case 'manhuaren':
            return ManhuarenSource(ManhuarenConfig.fromJson(def.config));
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

/// 无可用源时的哨兵源：[SourceManager.current] 在零源时返回它，避免各处 `.current` 崩溃。
///
/// 搜索/热门/最新/分类返回空；详情/章节/取图抛描述性错误，被调用方现有 try/catch 接住
/// （如详情页 _error、阅读器/书架 toast），引导用户去漫画源仓库添加云端源。
class _NoSource extends MangaSource {
  _NoSource();

  static const _msg = '暂无可用漫画源，请到「漫画源仓库」添加云端地址并更新';

  @override
  String get id => '__none__';

  @override
  String get name => '无可用源';

  @override
  String get lang => 'zh';

  @override
  bool get supportsLatest => false;

  @override
  Future<MangasPage> search(
    String query, {
    int page = 0,
    FilterList filters = const FilterList(),
  }) async => const MangasPage(items: [], hasNextPage: false);

  @override
  Future<MangasPage> getPopular({int page = 0}) async =>
      const MangasPage(items: [], hasNextPage: false);

  @override
  Future<MangasPage> getLatestUpdates({int page = 0}) async =>
      const MangasPage(items: [], hasNextPage: false);

  @override
  Future<CManga> getMangaDetails(CManga manga) async {
    throw StateError(_msg);
  }

  @override
  Future<List<CChapter>> getChapterList(CManga manga) async {
    throw StateError(_msg);
  }

  @override
  Future<List<String>> getChapterImages(CManga manga, CChapter chapter) async {
    throw StateError(_msg);
  }
}
