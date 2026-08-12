/// 漫画模型
class Comic {
  final String id;
  final String title;
  final String cover;
  final String? author;
  final String? alias;
  final String? description;
  final String? status;
  final List<String>? tags;
  final double? rating;
  final int? popular;
  final String pathWord;
  final String? sourceId; // 所属漫画源 id（收藏/书架角标用；旧数据为 null）
  final int? totalChapters;
  final DateTime? updateTime;

  const Comic({
    required this.id,
    required this.title,
    required this.cover,
    this.author,
    this.alias,
    this.description,
    this.status,
    this.tags,
    this.rating,
    this.popular,
    required this.pathWord,
    this.sourceId,
    this.totalChapters,
    this.updateTime,
  });

  factory Comic.fromJson(Map<String, dynamic> json) {
    // 安全解析字符串
    String? safeString(dynamic value) {
      if (value == null) return null;
      if (value is String) return value;
      return value.toString();
    }

    // 安全解析标签
    List<String>? safeTags(dynamic value) {
      if (value == null) return null;
      if (value is List) {
        return value
            .map((x) {
              if (x is Map) {
                return (x['name'] ?? x['tag'] ?? '').toString();
              }
              return x.toString();
            })
            .where((s) => s.isNotEmpty)
            .toList();
      }
      return null;
    }

    // 安全解析数字
    double? safeDouble(dynamic value) {
      if (value == null) return null;
      if (value is double) return value;
      if (value is int) return value.toDouble();
      if (value is String) return double.tryParse(value);
      return null;
    }

    int? safeInt(dynamic value) {
      if (value == null) return null;
      if (value is int) return value;
      if (value is double) return value.toInt();
      if (value is String) return int.tryParse(value);
      return null;
    }

    // 安全解析作者（可能是数组或字符串）
    String? safeAuthor(dynamic value) {
      if (value == null) return null;
      if (value is String) return value;
      if (value is List) {
        return value
            .map((x) {
              if (x is Map) {
                return x['name']?.toString() ?? '';
              }
              return x.toString();
            })
            .where((s) => s.isNotEmpty)
            .join(', ');
      }
      return value.toString();
    }

    // 安全解析别名（可能是字符串或数组）
    String? safeAlias(dynamic value) {
      if (value == null) return null;
      if (value is String) {
        final s = value.trim();
        return s.isEmpty ? null : s;
      }
      if (value is List) {
        final s = value
            .map((x) => x is Map ? (x['name']?.toString() ?? '') : x.toString())
            .where((s) => s.isNotEmpty)
            .join(', ');
        return s.isEmpty ? null : s;
      }
      return null;
    }

    // 安全解析状态（详情接口返回 {value, display} 对象）
    String? safeStatus(dynamic value) {
      if (value == null) return null;
      if (value is String) {
        final s = value.trim();
        return s.isEmpty ? null : s;
      }
      if (value is Map) {
        return value['display']?.toString() ?? value['value']?.toString();
      }
      return value.toString();
    }

    return Comic(
      // 搜索接口无 id，用 path_word 作为唯一标识（避免多本漫画 id 都是 "null"）
      id:
          safeString(json['path_word']) ??
          safeString(json['pathWord']) ??
          safeString(json['id']) ??
          '',
      title: safeString(json['name']) ?? safeString(json['title']) ?? '',
      cover: safeString(json['cover']) ?? '',
      author: safeAuthor(json['author']),
      alias: safeAlias(json['alias']),
      description:
          safeString(json['description']) ??
          safeString(json['synopsis']) ??
          safeString(json['brief']),
      status: safeStatus(json['status']),
      tags: safeTags(json['tags']) ?? safeTags(json['theme']),
      rating: safeDouble(json['rating']),
      popular: safeInt(json['popular']),
      pathWord:
          safeString(json['path_word']) ??
          safeString(json['pathWord']) ??
          safeString(json['id']) ??
          '',
      sourceId: safeString(json['sourceId']),
      totalChapters:
          safeInt(json['total_chapters']) ??
          safeInt(json['chapterCount']) ??
          safeInt(json['totalChapters']),
      updateTime: (json['update_time'] ?? json['datetime_updated']) != null
          ? DateTime.tryParse(
              (json['update_time'] ?? json['datetime_updated']).toString(),
            )
          : null,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'title': title,
      'cover': cover,
      'author': author,
      'alias': alias,
      'description': description,
      'status': status,
      'tags': tags,
      'rating': rating,
      'popular': popular,
      'pathWord': pathWord,
      'sourceId': sourceId,
      'totalChapters': totalChapters,
      'updateTime': updateTime?.toIso8601String(),
    };
  }

  Comic copyWith({
    String? id,
    String? title,
    String? cover,
    String? author,
    String? alias,
    String? description,
    String? status,
    List<String>? tags,
    double? rating,
    int? popular,
    String? pathWord,
    String? sourceId,
    int? totalChapters,
    DateTime? updateTime,
  }) {
    return Comic(
      id: id ?? this.id,
      title: title ?? this.title,
      cover: cover ?? this.cover,
      author: author ?? this.author,
      alias: alias ?? this.alias,
      description: description ?? this.description,
      status: status ?? this.status,
      tags: tags ?? this.tags,
      rating: rating ?? this.rating,
      popular: popular ?? this.popular,
      pathWord: pathWord ?? this.pathWord,
      sourceId: sourceId ?? this.sourceId,
      totalChapters: totalChapters ?? this.totalChapters,
      updateTime: updateTime ?? this.updateTime,
    );
  }
}

/// 漫画封面 Hero 动画 tag。
/// [prefix] 区分来源页面（搜索/收藏同时存活于 IndexedStack，避免同一漫画 tag 冲突）。
String comicCoverHeroTag(String prefix, Comic comic) =>
    '$prefix-cover-${comic.pathWord}';

/// 漫画章节
class ComicChapter {
  final String id;
  final String title;
  final int order;
  final int count;
  final String groupId;
  final String groupName;
  final DateTime? createTime;
  List<String>? imageUrls;

  ComicChapter({
    required this.id,
    required this.title,
    required this.order,
    required this.count,
    required this.groupId,
    required this.groupName,
    this.createTime,
    this.imageUrls,
  });

  factory ComicChapter.fromJson(Map<String, dynamic> json) {
    String? safeString(dynamic value) {
      if (value == null) return null;
      if (value is String) return value;
      return value.toString();
    }

    int safeInt(dynamic value, int defaultValue) {
      if (value == null) return defaultValue;
      if (value is int) return value;
      if (value is double) return value.toInt();
      if (value is String) return int.tryParse(value) ?? defaultValue;
      return defaultValue;
    }

    return ComicChapter(
      id: (json['uuid'] ?? json['id']).toString(),
      title: safeString(json['name']) ?? safeString(json['title']) ?? '',
      order: safeInt(json['ordered'] ?? json['order'], 0),
      count: safeInt(json['count'], 0),
      groupId:
          safeString(json['group_path_word'] ?? json['group_id']) ?? 'default',
      groupName: safeString(json['group_name']) ?? '默认',
      createTime: (json['datetime_created'] ?? json['create_time']) != null
          ? DateTime.tryParse(
              (json['datetime_created'] ?? json['create_time']).toString(),
            )
          : null,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'title': title,
      'order': order,
      'count': count,
      'groupId': groupId,
      'groupName': groupName,
      'createTime': createTime?.toIso8601String(),
      'imageUrls': imageUrls,
    };
  }
}

/// 章节分组
class ChapterGroup {
  final String id;
  final String name;
  final int count;
  final List<ComicChapter> chapters;

  ChapterGroup({
    required this.id,
    required this.name,
    required this.count,
    required this.chapters,
  });

  factory ChapterGroup.fromJson(Map<String, dynamic> json) {
    String? safeString(dynamic value) {
      if (value == null) return null;
      if (value is String) return value;
      return value.toString();
    }

    int safeInt(dynamic value, int defaultValue) {
      if (value == null) return defaultValue;
      if (value is int) return value;
      if (value is double) return value.toInt();
      if (value is String) return int.tryParse(value) ?? defaultValue;
      return defaultValue;
    }

    return ChapterGroup(
      id: (json['id'] ?? json['path_word']).toString(),
      name: safeString(json['name']) ?? '',
      count: safeInt(json['count'], 0),
      chapters: [],
    );
  }
}
