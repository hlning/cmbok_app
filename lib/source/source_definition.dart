// 漫画源统一配置定义（本地 JSON + 远端更新的载荷格式）。
//
// 顶层 JSON: {"version":1,"sources":[{type,engine?,config}, ...]}
// - type=config: config 体即 SiteConfig 字段，id 派生为 config:${name}（对齐 ConfigMangaSource.id）
// - type=api:   config 体含 id + 该 engine 的可变配置，由 SourceManager 按 engine 分发到
//               对应 Source 类（ZaimanhuaSource/CopyMangaSource）实例化
//
// 设计：SourceDefinition 只做轻量外壳（type/engine/raw config），不解析具体配置体——
// 具体解析交给 SourceManager 按 engine 调对应 Config.fromJson，便于后续新增 engine
// （如 copymanga 阶段2）零改本结构。

/// 单个漫画源的定义（外壳）。
class SourceDefinition {
  /// 全局唯一 id（config:${name} 或 api 协议标识如 zaimanhua）。
  /// 派生自配置体，保证与对应 Source.id 一致（currentSourceId 持久化依赖此一致性）。
  final String id;

  /// 'config' | 'api'
  final String type;

  /// type=api 时的引擎名：'zaimanhua' | 'copymanga' | ...（即代码逻辑骨架标识）
  final String? engine;

  /// 原始配置体（SiteConfig 或 ApiSourceConfig 的 JSON），由 SourceManager 按 type/engine 解析。
  final Map<String, dynamic> config;

  /// 是否需要魔法（代理/VPN）才能访问（源级元数据，非抓取配置）。
  final bool needsMagic;

  const SourceDefinition({
    required this.id,
    required this.type,
    this.engine,
    required this.config,
    this.needsMagic = false,
  });

  factory SourceDefinition.fromJson(Map<String, dynamic> j) {
    final type = (j['type'] as String?) ?? 'config';
    final engine = j['engine'] as String?;
    final config = (j['config'] as Map<String, dynamic>?) ?? const {};
    // id 派生：config 源用 config:${name}（对齐 ConfigMangaSource.id）；
    //          api 源用 config.id（协议标识，不可缺，缺省回退 engine）。
    final id = type == 'config'
        ? 'config:${config['name']}'
        : (config['id'] as String?) ?? engine ?? '';
    final needsMagic = (j['needsMagic'] as bool?) ?? false;
    return SourceDefinition(
      id: id,
      type: type,
      engine: engine,
      config: config,
      needsMagic: needsMagic,
    );
  }

  Map<String, dynamic> toJson() => {
    'type': type,
    if (engine != null) 'engine': engine,
    'config': config,
    if (needsMagic) 'needsMagic': true,
  };
}

/// 源配置文件顶层结构。
class SourceConfigFile {
  final int version;
  final List<SourceDefinition> sources;

  const SourceConfigFile({this.version = 1, required this.sources});

  factory SourceConfigFile.fromJson(Map<String, dynamic> j) {
    final arr = (j['sources'] as List?) ?? const [];
    return SourceConfigFile(
      version: (j['version'] as num?)?.toInt() ?? 1,
      sources: arr
          .whereType<Map<String, dynamic>>()
          .map(SourceDefinition.fromJson)
          .toList(),
    );
  }

  Map<String, dynamic> toJson() => {
    'version': version,
    'sources': sources.map((s) => s.toJson()).toList(),
  };
}
