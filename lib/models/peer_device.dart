/// 一个已发现 / 已配对的对端设备（手机或电脑）。
///
/// 鉴权模型（token-per-peer）：每对设备配对时生成一个共享 [token]，双方各存一份。
/// 不同设备对的 token 互不相同，因此多设备并存也互不影响。配对由接收方首次
/// 「接受传书」时触发：接收方生成 token 随 accept 响应回传，发送方持久化。
class PeerDevice {
  PeerDevice({
    required this.id,
    required this.name,
    required this.platform,
    this.token,
    this.host,
    this.port,
    this.online = false,
    this.lastSeen,
  });

  /// 安装级稳定 ID（随机 hex），与 mDNS TXT 属性 `id` 一致。
  final String id;

  /// 设备名（如「Cmbok手机-a1b2」/ 计算机名），用于 UI 展示。
  String name;

  /// 平台：android / windows / macos。
  final String platform;

  /// 与该对端共享的鉴权令牌（配对后双方一致）。请求方放 Authorization: Bearer。
  String? token;

  /// 当前 mDNS 解析到的局域网 IP（运行时，不持久化）。
  String? host;

  /// 服务端口（运行时，mDNS 解析得到）。
  int? port;

  /// 是否在线（运行时，由 mDNS 发现/丢失驱动）。
  bool online;

  /// 最近一次发现时间。
  DateTime? lastSeen;

  /// 令牌非空即视为已配对。
  bool get paired => token != null;

  /// 可达的「host:port」，未解析返回 null。
  String? get address => (host != null && port != null) ? '$host:$port' : null;

  /// 仅持久化稳定字段（host/port/online 为运行时态）。
  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'platform': platform,
    if (token != null) 'token': token,
  };

  factory PeerDevice.fromJson(Map<String, dynamic> json) => PeerDevice(
    id: json['id'] as String,
    name: json['name'] as String? ?? json['id'] as String,
    platform: json['platform'] as String? ?? 'unknown',
    token: json['token'] as String?,
  );

  @override
  String toString() =>
      'PeerDevice($name/$platform @ $address '
      '${online ? "在线" : "离线"}${paired ? "" : "(未配对)"})';
}
