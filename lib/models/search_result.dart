/// 搜索结果包装
class SearchResult<T> {
  final List<T> items;
  final int total;
  final int currentPage;
  final int totalPages;
  final bool hasMore;

  SearchResult({
    required this.items,
    required this.total,
    required this.currentPage,
    required this.totalPages,
  }) : hasMore = currentPage < totalPages;

  factory SearchResult.empty() {
    return SearchResult(items: [], total: 0, currentPage: 1, totalPages: 0);
  }

  SearchResult<R> map<R>(R Function(T) mapper) {
    return SearchResult<R>(
      items: items.map(mapper).toList(),
      total: total,
      currentPage: currentPage,
      totalPages: totalPages,
    );
  }
}

/// 下载状态
enum DownloadStatus { queued, downloading, completed, failed, cancelled }

/// 下载任务
class DownloadTask {
  final String id;
  final String comicId;
  final String comicTitle;
  final String comicCover;
  final String chapterId;
  final String chapterTitle;
  final DownloadStatus status;
  final int progress;
  final int total;
  final String? localPath;
  final DateTime createdAt;
  final DateTime? completedAt;
  final String? errorMessage;

  DownloadTask({
    required this.id,
    required this.comicId,
    required this.comicTitle,
    required this.comicCover,
    required this.chapterId,
    required this.chapterTitle,
    required this.status,
    this.progress = 0,
    this.total = 0,
    this.localPath,
    required this.createdAt,
    this.completedAt,
    this.errorMessage,
  });

  DownloadTask copyWith({
    String? id,
    String? comicId,
    String? comicTitle,
    String? comicCover,
    String? chapterId,
    String? chapterTitle,
    DownloadStatus? status,
    int? progress,
    int? total,
    String? localPath,
    DateTime? createdAt,
    DateTime? completedAt,
    String? errorMessage,
  }) {
    return DownloadTask(
      id: id ?? this.id,
      comicId: comicId ?? this.comicId,
      comicTitle: comicTitle ?? this.comicTitle,
      comicCover: comicCover ?? this.comicCover,
      chapterId: chapterId ?? this.chapterId,
      chapterTitle: chapterTitle ?? this.chapterTitle,
      status: status ?? this.status,
      progress: progress ?? this.progress,
      total: total ?? this.total,
      localPath: localPath ?? this.localPath,
      createdAt: createdAt ?? this.createdAt,
      completedAt: completedAt ?? this.completedAt,
      errorMessage: errorMessage ?? this.errorMessage,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'comicId': comicId,
      'comicTitle': comicTitle,
      'comicCover': comicCover,
      'chapterId': chapterId,
      'chapterTitle': chapterTitle,
      'status': status.index,
      'progress': progress,
      'total': total,
      'localPath': localPath,
      'createdAt': createdAt.toIso8601String(),
      'completedAt': completedAt?.toIso8601String(),
      'errorMessage': errorMessage,
    };
  }

  factory DownloadTask.fromJson(Map<String, dynamic> json) {
    return DownloadTask(
      id: json['id'],
      comicId: json['comicId'],
      comicTitle: json['comicTitle'],
      comicCover: json['comicCover'],
      chapterId: json['chapterId'],
      chapterTitle: json['chapterTitle'],
      status: DownloadStatus.values[json['status']],
      progress: json['progress'] ?? 0,
      total: json['total'] ?? 0,
      localPath: json['localPath'],
      createdAt: DateTime.parse(json['createdAt']),
      completedAt: json['completedAt'] != null
          ? DateTime.parse(json['completedAt'])
          : null,
      errorMessage: json['errorMessage'],
    );
  }
}
