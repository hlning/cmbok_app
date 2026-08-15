/// 书架条目类型
enum BookshelfItemType { comic, book }

/// 书架模型
class Bookshelf {
  final String id;
  final String name;
  final int sortOrder;
  final bool isPreset;
  final int createdAt;

  const Bookshelf({
    required this.id,
    required this.name,
    required this.sortOrder,
    required this.isPreset,
    required this.createdAt,
  });

  factory Bookshelf.fromJson(Map<String, dynamic> json) {
    return Bookshelf(
      id: json['id'] as String? ?? '',
      name: json['name'] as String? ?? '',
      sortOrder: json['sortOrder'] as int? ?? 0,
      isPreset: json['isPreset'] as bool? ?? false,
      createdAt: json['createdAt'] as int? ?? 0,
    );
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'sortOrder': sortOrder,
    'isPreset': isPreset,
    'createdAt': createdAt,
  };

  Bookshelf copyWith({
    String? id,
    String? name,
    int? sortOrder,
    bool? isPreset,
    int? createdAt,
  }) {
    return Bookshelf(
      id: id ?? this.id,
      name: name ?? this.name,
      sortOrder: sortOrder ?? this.sortOrder,
      isPreset: isPreset ?? this.isPreset,
      createdAt: createdAt ?? this.createdAt,
    );
  }
}

/// 书架条目（某本书在某个书架中）
class BookshelfItem {
  final String bookshelfId;
  final String itemId;
  final BookshelfItemType type;
  final int addedAt;

  /// 条目元数据快照（Book/Comic 的 JSON），让书架页不依赖收藏夹即可展示与打开
  final String? meta;

  const BookshelfItem({
    required this.bookshelfId,
    required this.itemId,
    required this.type,
    required this.addedAt,
    this.meta,
  });

  factory BookshelfItem.fromJson(Map<String, dynamic> json) {
    return BookshelfItem(
      bookshelfId: json['bookshelfId'] as String? ?? '',
      itemId: json['itemId'] as String? ?? '',
      type: _parseType(json['type']),
      addedAt: json['addedAt'] as int? ?? 0,
      meta: json['meta'] as String?,
    );
  }

  static BookshelfItemType _parseType(dynamic value) {
    if (value is String) {
      if (value == 'book') return BookshelfItemType.book;
    }
    return BookshelfItemType.comic;
  }

  Map<String, dynamic> toJson() => {
    'bookshelfId': bookshelfId,
    'itemId': itemId,
    'type': type.name,
    'addedAt': addedAt,
    'meta': meta,
  };
}
