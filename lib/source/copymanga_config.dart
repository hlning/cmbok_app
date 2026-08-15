// 拷贝漫画源（API 驱动）的可变配置。
//
// CopyMangaSource 是代码骨架（wrap ComicApi：搜索/详情/章节/取图/双路径/解密均复用），
// baseUrl 仍由 RemoteConfigService 动态给（ComicApi.baseUrl 读 copyApiUrl），不进配置。
// 本配置只承载可变元数据：id/显示名/防盗链 Referer/请求 UA——站点换域名或防盗链策略时
// 更新配置即可，无需发版。题材/排序维度是 copymanga 稳定分类，留作代码默认（同 manhuaren）。

/// 拷贝漫画源配置。
class CopymangaConfig {
  /// 全局唯一 id（协议标识，对齐 CopyMangaSource.id 与 currentSourceId 持久化）。
  final String id;

  /// 显示名。
  final String name;

  /// 图片下载防盗链 Referer（站点首页）。
  final String referer;

  /// 请求 UA（搜索/详情/取图统一）。
  final String ua;

  const CopymangaConfig({
    required this.id,
    required this.name,
    required this.referer,
    required this.ua,
  });

  static const _defaultUa =
      'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
      '(KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36';

  factory CopymangaConfig.fromJson(Map<String, dynamic> j) => CopymangaConfig(
    id: (j['id'] as String?) ?? 'copymanga',
    name: (j['name'] as String?) ?? '拷贝漫画',
    referer: (j['referer'] as String?) ?? 'https://2025copy.com/',
    ua: (j['ua'] as String?) ?? _defaultUa,
  );

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'referer': referer,
    'ua': ua,
  };
}
