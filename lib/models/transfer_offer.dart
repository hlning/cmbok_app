/// 一笔待传文件描述。
class TransferFile {
  const TransferFile({
    required this.name,
    required this.size,
    this.mime,
    this.kind = 'file',
    this.path,
  });

  /// 文件名（含扩展名）。
  final String name;

  /// 字节数。
  final int size;

  /// MIME（可空）。
  final String? mime;

  /// book / file：book 在手机端接收后自动入本地书架，file 落接收目录。
  final String kind;

  /// 发送方本地路径（接收方恒为 null）。
  final String? path;

  Map<String, dynamic> toJson() => {
    'name': name,
    'size': size,
    if (mime != null) 'mime': mime,
    'kind': kind,
  };

  factory TransferFile.fromJson(Map<String, dynamic> j) => TransferFile(
    name: j['name'] as String,
    size: (j['size'] as num).toInt(),
    mime: j['mime'] as String?,
    kind: j['kind'] as String? ?? 'file',
  );

  /// 扩展名（小写、无点）。
  String get ext {
    final dot = name.lastIndexOf('.');
    return dot <= 0 ? '' : name.substring(dot + 1).toLowerCase();
  }

  /// 去扩展名的标题（供入库）。
  String get title {
    final dot = name.lastIndexOf('.');
    return dot <= 0 ? name : name.substring(0, dot);
  }
}

/// 一次传书邀约的状态。
enum TransferStatus {
  pending,
  accepted,
  rejected,
  transferring,
  done,
  failed,
  expired,
}

/// 一次传书邀约。
///
/// 流程：发送方 POST /transfer/offer -> 接收方弹窗确认（含选目录）->
/// 发送方轮询结果 -> accepted 后逐个 POST /transfer -> /done。
class TransferOffer {
  TransferOffer({
    required this.id,
    required this.peerId,
    required this.peerName,
    required this.peerPlatform,
    required this.files,
    required this.kind,
    required this.createdAt,
    this.status = TransferStatus.pending,
    this.dir,
  });

  /// offerId（接收方生成）。
  final String id;

  /// 对端 id。
  final String peerId;

  /// 对端名。
  final String peerName;

  /// 对端平台。
  final String peerPlatform;

  /// 待传文件清单。
  final List<TransferFile> files;

  /// 整体类型（全为书则 book，否则 file），用于弹窗文案。
  final String kind;

  /// 状态。
  TransferStatus status;

  /// 接收方选定的目录（仅接收方有意义；默认各端下载位置下的 transfer/）。
  String? dir;

  /// 创建时间。
  final DateTime createdAt;

  /// 总字节数。
  int get totalSize => files.fold(0, (s, f) => s + f.size);

  /// 文件数。
  int get fileCount => files.length;

  /// 是否已过期（默认 2 分钟未响应）。
  bool isExpired({Duration timeout = const Duration(minutes: 2)}) =>
      DateTime.now().difference(createdAt) > timeout;
}
