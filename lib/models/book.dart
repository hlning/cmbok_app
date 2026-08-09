/// 图书模型（z-library 搜索结果）
/// 字段对应 cmbook service/cmbok_service.py _emit_success 精简后的结构，
/// 另含 description/pages/publisher 供详情页展示（搜索接口即返回）。
class Book {
  final String id;
  final String hash;
  final String title;
  final String? author;
  final String? cover;
  final String? year;
  final String? language;
  final String? extension;
  final String? filesizeString;
  final String? description;
  final String? pages;
  final String? publisher;
  final double? interestScore;
  final String? identifier; // ISBN

  const Book({
    required this.id,
    required this.hash,
    required this.title,
    this.author,
    this.cover,
    this.year,
    this.language,
    this.extension,
    this.filesizeString,
    this.description,
    this.pages,
    this.publisher,
    this.interestScore,
    this.identifier,
  });

  /// 安全取字符串（z-library 返回的 id/year/pages 等可能是 int）
  static String? safeString(dynamic value) {
    if (value == null) return null;
    if (value is String) return value;
    return value.toString();
  }

  /// 安全取浮点（interestScore 等可能是 int/double）
  static double? safeDouble(dynamic value) {
    if (value == null) return null;
    if (value is double) return value;
    if (value is int) return value.toDouble();
    if (value is String) return double.tryParse(value);
    return null;
  }

  factory Book.fromJson(Map<String, dynamic> json) {
    return Book(
      id: safeString(json['id']) ?? '',
      hash: safeString(json['hash']) ?? '',
      title: safeString(json['title']) ?? '',
      author: safeString(json['author']),
      cover: safeString(json['cover']),
      year: safeString(json['year']),
      language: safeString(json['language']),
      extension: safeString(json['extension']),
      filesizeString: safeString(json['filesizeString']),
      description: safeString(json['description']),
      pages: safeString(json['pages']),
      publisher: safeString(json['publisher']),
      interestScore: safeDouble(json['interestScore']),
      identifier: safeString(json['identifier']),
    );
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'hash': hash,
    'title': title,
    'author': author,
    'cover': cover,
    'year': year,
    'language': language,
    'extension': extension,
    'filesizeString': filesizeString,
    'description': description,
    'pages': pages,
    'publisher': publisher,
    'interestScore': interestScore,
    'identifier': identifier,
  };

  Book copyWith({
    String? id,
    String? hash,
    String? title,
    String? author,
    String? cover,
    String? year,
    String? language,
    String? extension,
    String? filesizeString,
    String? description,
    String? pages,
    String? publisher,
    double? interestScore,
    String? identifier,
  }) {
    return Book(
      id: id ?? this.id,
      hash: hash ?? this.hash,
      title: title ?? this.title,
      author: author ?? this.author,
      cover: cover ?? this.cover,
      year: year ?? this.year,
      language: language ?? this.language,
      extension: extension ?? this.extension,
      filesizeString: filesizeString ?? this.filesizeString,
      description: description ?? this.description,
      pages: pages ?? this.pages,
      publisher: publisher ?? this.publisher,
      interestScore: interestScore ?? this.interestScore,
      identifier: identifier ?? this.identifier,
    );
  }
}

/// 格式下拉选项（对应 cmbook book_search_card.py extensionsComboBox）
/// 第一项为「全部」（不传 extensions 参数），其余为 z-library 支持的格式。
class BookFormat {
  final String label;
  final String? value; // null = 全部（不筛选）

  const BookFormat(this.label, this.value);

  static const List<BookFormat> all = [
    BookFormat('全部', null),
    BookFormat('EPUB', 'EPUB'),
    BookFormat('AZW', 'AZW'),
    BookFormat('AZW3', 'AZW3'),
    BookFormat('MOBI', 'MOBI'),
    BookFormat('PDF', 'PDF'),
    BookFormat('TXT', 'TXT'),
    BookFormat('CBZ', 'CBZ'),
    BookFormat('DJV', 'DJV'),
    BookFormat('DJVU', 'DJVU'),
    BookFormat('FB2', 'FB2'),
    BookFormat('LIT', 'LIT'),
    BookFormat('RTF', 'RTF'),
  ];

  /// 常见格式（搜索页小标签用，只列主流类型）
  static const List<BookFormat> common = [
    BookFormat('全部', null),
    BookFormat('EPUB', 'EPUB'),
    BookFormat('PDF', 'PDF'),
    BookFormat('MOBI', 'MOBI'),
    BookFormat('AZW3', 'AZW3'),
    BookFormat('TXT', 'TXT'),
    BookFormat('FB2', 'FB2'),
  ];
}
