import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import '../models/comic.dart';
import '../models/search_result.dart';
import 'crypto.dart';
import 'remote_config_service.dart';

/// 日志工具
void _log(String message) {
  if (kDebugMode) {
    print('[ComicApi] $message');
  }
}

/// 截断长字段用于日志输出
String _truncate(dynamic value, [int max = 60]) {
  if (value == null) return 'null';
  final s = value.toString();
  return s.length > max ? '${s.substring(0, max)}...' : s;
}

/// 拷贝漫画 API 客户端（对应 Python utils/client_util.py create_api_client）
/// 浏览器风请求头避免"破解版"风控，含 3 次重试（429/5xx）
class ComicApi {
  static const _browserUa =
      'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
      '(KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36';

  static const _hotmangaHosts = {
    'api.manga2025.com',
    'mapi.hotmangasd.com',
    'mapi.hotmangasf.com',
    'mapi.hotmangasg.com',
    'mapi.elfgjfghkk.club',
    'mapi.fgjfghkk.club',
    'mapi.fgjfghkkcenter.club',
  };

  final Dio dio;
  final String? _baseUrlOverride;
  final String? token;

  /// 拷贝漫画 API 地址：优先构造传入的 override，否则读远程配置
  /// （RemoteConfigService 默认回退 AppConstants.defaultCopyApiUrl，无配置时与原硬编码一致）
  String get baseUrl => _baseUrlOverride ?? RemoteConfigService().copyApiUrl;

  ComicApi({String? baseUrl, this.token})
    : _baseUrlOverride = baseUrl,
      dio = Dio(
        BaseOptions(
          connectTimeout: const Duration(seconds: 15),
          receiveTimeout: const Duration(seconds: 15),
        ),
      ) {
    _log('初始化 API 客户端，baseUrl: $baseUrl');
    dio.interceptors.add(
      InterceptorsWrapper(
        onRequest: (o, h) {
          o.headers.addAll(_headersFor(o.uri.toString()));
          _log('请求: ${o.method} ${o.uri}');
          h.next(o);
        },
        onResponse: (r, h) {
          _log('响应状态: ${r.statusCode}, 数据长度: ${r.data.toString().length}');
          h.next(r);
        },
        onError: (e, h) async {
          _log('请求错误: ${e.message}, 状态码: ${e.response?.statusCode}');
          final code = e.response?.statusCode ?? 0;
          if ([429, 500, 502, 503, 504].contains(code)) {
            final n = (e.requestOptions.extra['retry'] ?? 0) + 1;
            if (n <= 3) {
              _log('重试第 $n 次...');
              e.requestOptions.extra['retry'] = n;
              await Future.delayed(Duration(seconds: n));
              try {
                return h.resolve(await dio.fetch(e.requestOptions));
              } catch (err) {
                return h.next(err is DioException ? err : e);
              }
            }
          }
          h.next(e);
        },
      ),
    );
  }

  /// 搜索漫画（对应 Python ComicSearch）
  Future<SearchResult<Comic>> searchComic(
    String keyword, {
    int page = 0,
    int limit = 27,
  }) async {
    _log('=' * 50);
    _log('开始搜索: "$keyword", 页码: $page, 每页: $limit');

    try {
      final url = '${baseUrl}api/v3/search/comic';
      _log('请求URL: $url');

      final response = await dio.get(
        url,
        queryParameters: {
          'format': 'json',
          'platform': '1',
          'q': keyword,
          'limit': limit,
          'offset': page * limit,
        },
      );

      _log('原始响应类型: ${response.data.runtimeType}');
      _log(
        '原始响应键: ${response.data is Map ? (response.data as Map).keys.toList() : "不是Map"}',
      );

      final data = _parseResponse(response);
      _log('解析后数据键: ${data.keys.toList()}');

      // 尝试不同的数据路径（兼容 results 和 data）
      List<dynamic> list = [];
      int total = 0;

      // 直接从 data 获取（_parseResponse 已经处理了 results）
      if (data.containsKey('list')) {
        list = data['list'] as List? ?? [];
        total = data['total'] ?? 0;
        _log('从 data.list 获取，数量: ${list.length}, 总数: $total');
      }
      // 尝试从 data['data'] 获取
      else if (data.containsKey('data') && data['data'] is Map) {
        final innerData = data['data'] as Map;
        list = innerData['list'] as List? ?? [];
        total = innerData['total'] ?? 0;
        _log('从 data.data.list 获取，数量: ${list.length}, 总数: $total');
      }
      // 尝试从 data['comics'] 获取
      else if (data.containsKey('comics')) {
        list = data['comics'] as List? ?? [];
        total = data['total'] ?? list.length;
        _log('从 data.comics 获取，数量: ${list.length}, 总数: $total');
      } else {
        _log('警告: 没有找到列表数据！');
      }

      _log('开始解析 ${list.length} 条漫画数据...');

      final comics = <Comic>[];
      for (var i = 0; i < list.length; i++) {
        try {
          final item = list[i];
          if (item is Map<String, dynamic>) {
            if (i == 0) {
              _log('首条原始字段: ${item.keys.toList()}');
            }
            _log(
              '解析第 ${i + 1} 条: name=${item['name']}, path_word=${item['path_word']}',
            );
            comics.add(Comic.fromJson(item));
          }
        } catch (e) {
          _log('解析第 $i 条失败: $e');
        }
      }

      _log('成功解析 ${comics.length} 条漫画');
      _log('=' * 50);

      return SearchResult<Comic>(
        items: comics,
        total: total,
        currentPage: page + 1,
        totalPages: (total / limit).ceil(),
      );
    } catch (e) {
      _log('搜索失败: $e');
      _log('=' * 50);
      rethrow;
    }
  }

  /// 按题材分类拉取漫画（走 www 网页域 SSR，非 API 子域）。
  ///
  /// copymanga 搜索接口不支持分类（theme 被忽略），分类列表只能走网页
  /// `/comics?theme=<拼音>`，数据 SSR 注入在 `exemptComic-box` 的 `list` 属性
  /// （HTML 实体编码的 Python 风格 dict 列表）。详见记忆 copymanga-theme-category-browse。
  ///
  /// 注意：www 网页域请求**不能带 `webp:0` 头**（会让 SSR 返空 total=0），故用独立
  /// Dio 而非主 dio（主 dio 的 interceptor 会加 webp:0）。
  Future<SearchResult<Comic>> getCategoryComics(
    String theme, {
    int page = 0,
    int limit = 20,
    String ordering = '-datetime_updated',
  }) async {
    final offset = page * limit;
    _log('分类筛选: theme=$theme, page=$page($offset), limit=$limit');

    try {
      // 独立 Dio：www 网页域头不能带 webp:0（致 SSR 返空），不复用主 dio interceptor
      final webDio = Dio(
        BaseOptions(
          connectTimeout: const Duration(seconds: 15),
          receiveTimeout: const Duration(seconds: 15),
        ),
      );
      final qp = <String, dynamic>{
        'ordering': ordering,
        'limit': limit,
        'offset': offset,
      };
      if (theme.isNotEmpty) qp['theme'] = theme;

      final response = await webDio.get(
        'https://www.copy3000.com/comics',
        queryParameters: qp,
        options: Options(
          responseType: ResponseType.plain,
          headers: const {
            'User-Agent': _browserUa,
            'version': '2025.05.09',
            'region': '0',
            'Origin': 'https://2025copy.com',
            'Referer': 'https://2025copy.com/',
            'sec-fetch-dest': 'document',
            'sec-fetch-mode': 'navigate',
            'sec-fetch-site': 'same-origin',
          },
        ),
      );
      final html = (response.data ?? '').toString();

      // total 从 <div class="exemptComic-box" total="N" ...>
      final totalMatch = RegExp(
        r'exemptComic-box[^>]*total="(\d+)"',
      ).firstMatch(html);
      final total = int.tryParse(totalMatch?.group(1) ?? '') ?? 0;

      // list="..."：内容为 HTML 实体编码的 Python dict 列表
      final listMatch = RegExp(r'list="([^"]*)"').firstMatch(html);
      if (listMatch == null) {
        _log('分类筛选: 未找到 list 属性，返回空（total=$total）');
        return SearchResult<Comic>(
          items: [],
          total: total,
          currentPage: page + 1,
          totalPages: (total / limit).ceil(),
        );
      }

      // HTML unescape + 单引号转双引号 -> 合法 JSON
      final raw = listMatch
          .group(1)!
          .replaceAll('&#x27;', "'")
          .replaceAll('&#39;', "'")
          .replaceAll('&amp;', '&')
          .replaceAll('&quot;', '"')
          .replaceAll('&lt;', '<')
          .replaceAll('&gt;', '>')
          .replaceAll("'", '"');
      final List<dynamic> data = jsonDecode(raw) as List;

      final comics = <Comic>[];
      for (final item in data) {
        if (item is! Map<String, dynamic>) continue;
        try {
          final m = Map<String, dynamic>.from(item);
          // SSR status 是数字 0/1，转中文显示（1=已完结, 0=连载中，详情页实测验证）
          final st = m['status'];
          m['status'] = st == 1 ? '已完结' : (st == 0 ? '连载中' : st);
          comics.add(Comic.fromJson(m));
        } catch (e) {
          _log('分类筛选解析单条失败: $e');
        }
      }
      _log('分类筛选: theme=$theme, 解析 ${comics.length} 条, 共 $total');
      return SearchResult<Comic>(
        items: comics,
        total: total,
        currentPage: page + 1,
        totalPages: (total / limit).ceil(),
      );
    } catch (e) {
      _log('分类筛选失败: $e');
      rethrow;
    }
  }

  /// 单次请求 comic2/{pathWord}，返回解析后的 results
  /// 详情(comic)与分组(groups)都来自这次响应，合并以避免对同一端点重复请求
  Future<Map<String, dynamic>> _fetchComicResults(String pathWord) async {
    _log('请求 comic2: $pathWord');
    final url = '${baseUrl}api/v3/comic2/$pathWord?platform=1';
    final response = await dio.get(url);
    _log(
      'comic2 响应: 状态=${response.statusCode}, 类型=${response.data.runtimeType}',
    );
    if (response.data is Map) {
      _log('comic2 顶层 keys: ${(response.data as Map).keys.toList()}');
    }
    final data = _parseResponse(response);
    _log('comic2 解析后 keys: ${data.keys.toList()}');
    return data;
  }

  /// 解析 groups（dict，key 为分组 path_word）并为每个分组拉取章节列表
  Future<List<ChapterGroup>> _parseGroupsAndChapters(
    String comicPathWord,
    dynamic groupsMap,
  ) async {
    _log('groups 类型: ${groupsMap.runtimeType}');
    if (groupsMap is Map) {
      _log('groups keys: ${groupsMap.keys.toList()}');
    }
    final result = <ChapterGroup>[];

    if (groupsMap is Map) {
      for (final entry in groupsMap.entries) {
        final g = entry.value;
        if (g is! Map) continue;
        final groupPathWord = (g['path_word'] ?? entry.key).toString();
        _log(
          '分组 entry: key=${entry.key}, path_word=${g['path_word']}, '
          'name=${g['name']}, count=${g['count']}, keys=${g.keys.toList()}',
        );
        final groupData = await _getChapterGroup(comicPathWord, groupPathWord);
        final group = ChapterGroup.fromJson(Map<String, dynamic>.from(g));
        group.chapters.addAll(groupData);
        result.add(group);
      }
    } else {
      _log('警告: groups 不是 Map（实际 ${groupsMap.runtimeType}），无法解析分组');
    }

    _log('章节分组解析完成: ${result.length} 个分组');
    return result;
  }

  /// 一次请求同时获取漫画详情与章节分组（合并原 getComicDetail + getChapters）
  /// 详情页应使用本方法，避免对 comic2/{pathWord} 发起两次相同请求
  Future<({Comic comic, List<ChapterGroup> groups})> getComicDetailAndChapters(
    String pathWord,
  ) async {
    final data = await _fetchComicResults(pathWord);

    final comicJson = data['comic'] ?? data;
    _log(
      'comic 字段来源: ${data.containsKey('comic') ? "data['comic']" : 'fallback(data)'}',
    );
    if (comicJson is Map) {
      _log('comic keys: ${comicJson.keys.toList()}');
      _log(
        'comic 原始字段: status=${comicJson['status']}, tags=${comicJson['tags']}, '
        'theme=${comicJson['theme']}, brief=${_truncate(comicJson['brief'])}, '
        'description=${_truncate(comicJson['description'])}',
      );
    }
    final comic = Comic.fromJson(
      comicJson is Map ? Map<String, dynamic>.from(comicJson) : const {},
    );
    _log(
      '详情解析结果: status=${comic.status}, tags=${comic.tags}, '
      'description长度=${comic.description?.length ?? 0}, '
      'author=${comic.author}, totalChapters=${comic.totalChapters}',
    );

    final groups = await _parseGroupsAndChapters(pathWord, data['groups']);
    return (comic: comic, groups: groups);
  }

  /// 获取漫画详情（对应 Python ComicGroups）
  /// 注意：本方法与 getChapters 各自请求一次 comic2；详情页请改用
  /// getComicDetailAndChapters 合并请求，避免重复
  Future<Comic> getComicDetail(String pathWord) async {
    final data = await _fetchComicResults(pathWord);
    final comicJson = data['comic'] ?? data;
    if (comicJson is Map) {
      _log(
        'comic 原始字段: status=${comicJson['status']}, theme=${comicJson['theme']}, '
        'brief=${_truncate(comicJson['brief'])}',
      );
    }
    final comic = Comic.fromJson(
      comicJson is Map ? Map<String, dynamic>.from(comicJson) : const {},
    );
    _log(
      '详情解析结果: status=${comic.status}, tags=${comic.tags}, '
      'description长度=${comic.description?.length ?? 0}, author=${comic.author}',
    );
    return comic;
  }

  /// 获取章节分组列表
  /// 分组列表接口 /comic/{path}/group 已失效（404），改从详情接口 comic2/{path}
  /// 的 results.groups（dict，key 为分组 path_word）获取分组元数据
  Future<List<ChapterGroup>> getChapters(String comicPathWord) async {
    final data = await _fetchComicResults(comicPathWord);
    return _parseGroupsAndChapters(comicPathWord, data['groups']);
  }

  /// 获取单个分组的章节（对应 Python ComicChapters）
  Future<List<ComicChapter>> _getChapterGroup(
    String comicPathWord,
    String groupId,
  ) async {
    _log('获取章节列表: $comicPathWord / $groupId');
    final url =
        '${baseUrl}api/v3/comic/$comicPathWord/group/$groupId/chapters?limit=500&offset=0';
    final response = await dio.get(url);
    final data = _parseResponse(response);
    _log('章节列表解析后 keys: ${data.keys.toList()}');
    final list = data['list'] as List? ?? [];
    _log('章节列表数量: ${list.length}');
    if (list.isNotEmpty && list.first is Map) {
      _log('首条章节 keys: ${(list.first as Map).keys.toList()}');
    }
    // order 取 API 返回的 list 顺序（源站原始顺序），替代不可靠的 ordered 字段
    // （ordered 疑似全 0/倒序）。list 默认按更新时间倒序（最新在前），
    // UI 据 CopyMangaSource.chapterOrderDescending=true 降序排得「第1话在前」。
    final chapters = <ComicChapter>[];
    for (var i = 0; i < list.length; i++) {
      final cc = ComicChapter.fromJson(list[i]);
      chapters.add(
        ComicChapter(
          id: cc.id,
          title: cc.title,
          order: i,
          count: cc.count,
          groupId: cc.groupId,
          groupName: cc.groupName,
          createTime: cc.createTime,
        ),
      );
    }
    if (chapters.isNotEmpty) {
      _log(
        '章节顺序(list[0]=最新?): 首=${chapters.first.title}, 尾=${chapters.last.title}',
      );
    }
    return chapters;
  }

  /// 获取章节图片（对应 Python get_chapter_images，双路径回退）
  Future<List<String>> getChapterImages(
    String comicPathWord,
    String chapterId,
  ) async {
    _log('获取章节图片: $comicPathWord / $chapterId');
    // 热辣线路用 chapter，copy 线路用 chapter2；两者回退（参考 Breeze 插件）
    for (final path in ['chapter', 'chapter2']) {
      try {
        final url =
            '${baseUrl}api/v3/comic/$comicPathWord/$path/$chapterId?platform=1';
        final response = await dio.get(url);
        final data = _parseResponse(response);
        final chapter = data['chapter'] ?? {};
        final contents = chapter['contents'] as List? ?? [];
        if (contents.isNotEmpty) {
          _log('通过 $path 路径获取到 ${contents.length} 张图片');
          return contents.map((x) => x['url'].toString()).toList();
        }
      } catch (e) {
        _log('$path 路径失败: $e');
      }
    }
    _log('所有路径都失败了');
    return [];
  }

  /// 解析响应（处理加密数据，对应 Python base_utils.py analyze_data）
  Map<String, dynamic> _parseResponse(Response response) {
    _log('开始解析响应...');
    final data = response.data;

    if (data is Map<String, dynamic>) {
      _log('响应是 Map 类型');

      // 业务状态码与消息（copymanga 错误响应靠 message 说明原因）
      final code = data['code'];
      final message = data['message'];
      _log('业务码: code=$code, message=$message');
      // 非成功或体积极小时，打印完整响应体以便定位错误
      if (code != 200 || data.toString().length < 500) {
        _log('完整响应体: $data');
      }

      // 检查是否为加密响应
      if (data.containsKey('manga2025_data') || data.containsKey('enc_data')) {
        _log('检测到加密数据');
        final encData = data['manga2025_data'] ?? data['enc_data'];
        if (encData is String && encData.isNotEmpty) {
          try {
            final decrypted = ComicCrypto.analyzeData(encData);
            _log('解密成功');
            return decrypted;
          } catch (e) {
            _log('解密失败: $e');
          }
        }
      }

      // 处理 results 包装结构（API实际返回的格式，对应 Python data["results"]）
      if (data.containsKey('results')) {
        _log('找到 results 字段');
        final r = data['results'];
        if (r is Map<String, dynamic>) {
          _log('results 是 Map，返回它，keys: ${r.keys.toList()}');
          return r;
        } else {
          _log('results 类型是: ${r.runtimeType}');
        }
      }

      // 直接返回数据
      if (data.containsKey('data')) {
        _log('找到 data 字段');
        final d = data['data'];
        if (d is Map<String, dynamic>) return d;
        if (d is String && d.isNotEmpty) {
          try {
            return ComicCrypto.analyzeData(d);
          } catch (_) {}
        }
        return data;
      }
      return data;
    }

    if (data is String && data.isNotEmpty) {
      _log('响应是 String 类型，尝试解密');
      try {
        return ComicCrypto.analyzeData(data);
      } catch (e) {
        _log('解密失败: $e');
      }
    }

    _log('无法解析响应，返回空');
    return {};
  }

  bool _isHotmanga(String url) {
    final host = Uri.tryParse(url)?.host.toLowerCase() ?? '';
    return _hotmangaHosts.contains(host) ||
        host.contains('hotmanga') ||
        host.contains('fgjfghkk');
  }

  Map<String, String> _headersFor(String url) {
    final hot = _isHotmanga(url);
    final h = <String, String>{
      'Accept': 'application/json',
      'Accept-Language': 'en-US,en;q=0.9,zh-TW;q=0.8,zh;q=0.7',
      'version': hot ? '2025.02.12' : '2025.05.09',
      'sec-fetch-dest': 'document',
      'sec-fetch-mode': 'navigate',
      'sec-fetch-site': 'same-origin',
      'sec-fetch-user': '?1',
      'upgrade-insecure-requests': '1',
      'User-Agent': _browserUa,
      'platform': '1',
      'Origin': hot ? 'https://m.relamanhua.org' : 'https://2025copy.com',
      'webp': hot ? '1' : '0',
    };
    if (!hot) h['region'] = '0';
    final t = (token ?? '').trim();
    if (t.isNotEmpty) h['authorization'] = 'Token $t';
    return h;
  }
}
