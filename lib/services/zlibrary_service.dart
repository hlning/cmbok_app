import 'dart:async';
import 'dart:convert';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:html/dom.dart' as html_element;
import 'package:html/parser.dart' as html_parser;
import 'package:shared_preferences/shared_preferences.dart';
import '../models/book.dart';
import '../models/book_category.dart';
import '../models/search_result.dart';
import '../source/webview_image_fetcher.dart';
import 'builtin_accounts.dart';
import 'remote_config_service.dart';
import 'settings_service.dart';

void _log(String message) {
  if (kDebugMode) debugPrint('[Zlibrary] $message');
}

/// z-library 下载链接信息（对应 cmbook Zlibrary.getDownloadLink 返回）
class DownloadLink {
  final String filename;
  final String url;
  final Map<String, String> headers;
  const DownloadLink({
    required this.filename,
    required this.url,
    required this.headers,
  });
}

/// z-library 业务异常
class ZlibraryException implements Exception {
  /// no_account / no_login / unavailable / quota_exceeded / rate_limited / fail
  final String code;
  final String message;
  ZlibraryException(this.code, this.message);
  @override
  String toString() => 'ZlibraryException($code): $message';
}

/// verifyToken 复校结果：valid=token 有效 / invalid=token 失效 / unavailable=地址不可用
enum _TokenState { valid, invalid, unavailable }

/// z-library 登录/注册/搜索/下载链接服务 + 每日限额（单例 ChangeNotifier）
/// 对应 cmbook service/zlibrary_client.py + service/cmbok_service.py 图书部分。
/// 已登录自有账号时优先用自有 token，否则轮询内置账号。
class ZlibraryService extends ChangeNotifier {
  ZlibraryService._();
  static final ZlibraryService _instance = ZlibraryService._();
  factory ZlibraryService() => _instance;

  static const _kDomain = 'zlibrary_domain';
  static const _kEmail = 'zlibrary_email';
  static const _kUsername = 'zlibrary_username';
  static const _kRemixUserid = 'zlibrary_remix_userid';
  static const _kRemixUserkey = 'zlibrary_remix_userkey';

  /// 内置账号全局每日限额 / 自有账号每日限额（对应 cmbook BUILTIN_DAILY_LIMIT / LOGGED_DAILY_LIMIT）
  static const int builtinDailyLimit = 5;
  static const int loggedDailyLimit = 10;
  static const _kBuiltinCount = 'zlibrary_builtin_count'; // JSON {date, count}

  /// 候选节点列表（启动探测写回 + 运行时重定向发现新域名追加；JSON [domain,...]）
  static const _kCandidates = 'zlibrary_url_candidates';
  static const _kCategories =
      'zlibrary_categories'; // JSON [{title,children:[{id,slug,zhName}]}]
  static const _kMaxRetries = 3; // 429/5xx 同域名退避重试次数
  static const _kRetryStatus = {429, 500, 502, 503, 504};
  static const _kHealthInterval = Duration(hours: 1);

  static const _browserUa =
      'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
      '(KHTML, like Gecko) Chrome/110.0.0.0 Safari/537.36';

  final Dio _dio = Dio(
    BaseOptions(
      connectTimeout: const Duration(seconds: 20),
      receiveTimeout: const Duration(seconds: 30),
      followRedirects: false, // 手动处理 301/302 以更新并持久化域名
      responseType: ResponseType.plain, // 自行 jsonDecode，规避 Cloudflare HTML 页抛异常
      validateStatus: (_) => true, // 不按状态码抛异常，自行判断
    ),
  );

  String _domain = ''; // 不含 scheme，如 zh.zlibrary.by
  String _email = '';
  String _username = '';
  String _remixUserid = '';
  String _remixUserkey = '';

  /// 自有账号服务端每日下载限额（来自 /eapi/user/profile；null=未取到，回退硬编码）
  int? _serverDownloadsLimit;

  /// 自有账号服务端今日已下载数（来自 /eapi/user/profile，纯服务端判定，不落盘）。
  /// 每次重启 App 由 refreshUserProfile() 重新拉取；自登账号不使用本地计数。
  int _serverDownloadsToday = 0;

  /// 分类页书的 eapi 匹配缓存（bookId -> 匹配到的带 eapi hash 的 Book）。
  /// 会话级内存缓存，避免同一本分类书重复点击反复发 eapi 搜索。不落盘。
  final Map<String, Book> _categoryMatchCache = {};

  /// 内置账号 token 缓存（避免每次搜索都重新登录）
  String? _builtinUserid;
  String? _builtinUserkey;

  /// 候选节点列表（启动探测写回 + 运行时重定向发现新域名追加）
  List<String> _candidates = [];

  /// 地址是否不可用（全候选连接失败/404）；仅状态变化才 notify
  bool _unavailable = false;

  /// 定时健康检查（复用本地候选探测，30 分钟一次）
  Timer? _healthTimer;

  /// 已应用的云端 zlibrary_url（去重，避免 RemoteConfig 重复通知触发重复探测）
  Object? _lastAppliedCloud;

  /// 本次取下载链接是否检测到额度用完（disallowDownloadMessage 含 limit）
  bool _quotaExceeded = false;

  String get domain => _domain;
  String get email => _email;
  String get username => _username;
  String get remixUserid => _remixUserid;
  bool get isLoggedIn => _remixUserid.isNotEmpty && _remixUserkey.isNotEmpty;

  /// 供在线阅读 WebView 注入登录态：已登录返回 cookie（remix_userid/remix_userkey
  /// + siteLanguageV2），未登录返回空 map（由调用方决定是否降级）。
  Map<String, String> cookiesForWebview() =>
      isLoggedIn ? _cookies(_remixUserid, _remixUserkey) : const {};

  /// 自有账号服务端每日下载限额（未取到时为 null，调用方应回退 loggedDailyLimit）
  int? get serverDownloadsLimit => _serverDownloadsLimit;

  /// 地址是否不可用（全候选连接失败/404）。UI 据此提示「图书功能暂不可用」。
  bool get isUnavailable => _unavailable;

  /// 候选节点列表（只读视图）
  List<String> get candidates => List.unmodifiable(_candidates);

  /// 初始化：加载登录态、域名、每日计数
  Future<void> init() async {
    final prefs = await SharedPreferences.getInstance();
    _domain = prefs.getString(_kDomain) ?? _defaultDomain();
    _email = prefs.getString(_kEmail) ?? '';
    _username = prefs.getString(_kUsername) ?? '';
    _remixUserid = prefs.getString(_kRemixUserid) ?? '';
    _remixUserkey = prefs.getString(_kRemixUserkey) ?? '';
    _candidates = _decodeCandidates(prefs.getString(_kCandidates));
    // 当前域名不在候选里则插最前，确保至少有一个候选可用（兼容手动/老配置）
    if (_domain.isNotEmpty && !_candidates.contains(_domain)) {
      _candidates.insert(0, _domain);
    }
    await _loadCounts();
    _loadCategoriesCache(prefs);
    _log(
      'init: domain=$_domain, candidates=$_candidates, '
      'loggedIn=$isLoggedIn',
    );
    notifyListeners();
    if (isLoggedIn) refreshUserProfile(); // fire-and-forget：校准服务端限额与已下载数
    _healthTimer?.cancel();
    _healthTimer = Timer.periodic(_kHealthInterval, (_) => _healthCheck());
    // 监听云端配置：RemoteConfig 拉到 zlibrary_url 后探测选优
    RemoteConfigService().removeListener(_onRemoteConfigChanged);
    RemoteConfigService().addListener(_onRemoteConfigChanged);
    _applyCloudCandidatesIfAvailable();
  }

  /// RemoteConfig 变更回调：云端拉到 zlibrary_url 后探测选优。
  void _onRemoteConfigChanged() {
    _applyCloudCandidatesIfAvailable();
  }

  void _applyCloudCandidatesIfAvailable() {
    final cloud = RemoteConfigService().cloudZlibraryUrl;
    if (cloud == null || cloud == _lastAppliedCloud) return;
    _lastAppliedCloud = cloud;
    applyCloudCandidates(cloud); // fire-and-forget
  }

  static String _defaultDomain() => RemoteConfigService().zlibraryDomain;

  Future<void> _persistDomain() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_kDomain, _domain);
  }

  Future<void> _persistCandidates() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_kCandidates, jsonEncode(_candidates));
  }

  /// 从 prefs 加载分类目录缓存到 [BookCategories.groups]（启动即有数据，不等网络）。
  void _loadCategoriesCache(SharedPreferences prefs) {
    final raw = prefs.getString(_kCategories);
    if (raw == null || raw.isEmpty) return;
    try {
      final list = jsonDecode(raw) as List;
      final groups = list
          .map((e) => BookCategoryGroup.fromJson(e as Map<String, dynamic>))
          .toList();
      if (groups.isNotEmpty) {
        BookCategories.groups = groups;
        _log('分类缓存加载: ${groups.length} 组');
      }
    } catch (e) {
      _log('分类缓存加载失败: $e');
    }
  }

  Future<void> _persistCategories() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      _kCategories,
      jsonEncode(BookCategories.groups.map((g) => g.toJson()).toList()),
    );
  }

  /// 候选域名遍历顺序：当前域名在前，其余候选按列表顺序，去重。
  List<String> _candidateOrder() {
    final order = <String>[];
    if (_domain.isNotEmpty) order.add(_domain);
    for (final d in _candidates) {
      if (d.isNotEmpty && !order.contains(d)) order.add(d);
    }
    return order;
  }

  /// 把域名加入候选列表最前并持久化（已存在则提到最前）。供重定向发现新域名时调用。
  void _addCandidate(String? newDomain) {
    if (newDomain == null || newDomain.isEmpty) return;
    _candidates.remove(newDomain);
    _candidates.insert(0, newDomain);
    _persistCandidates();
  }

  /// 标记可用性状态，仅状态变化才 notify（避免无谓重建）。
  void _setUnavailable(bool v) {
    if (_unavailable == v) return;
    _unavailable = v;
    notifyListeners();
  }

  // -------------------- 登录 / 注册 --------------------

  /// 邮箱密码登录（自有账号）。成功保存 token。对应 cmbook Zlibrary.login
  Future<bool> login(String email, String password) async {
    final res = await _post(
      '/eapi/user/login',
      data: {'email': email, 'password': password},
    );
    if (_isSuccess(res) && res['user'] is Map) {
      final user = res['user'] as Map;
      final uid = (user['id'] ?? '').toString();
      final key = (user['remix_userkey'] ?? '').toString();
      if (uid.isEmpty || key.isEmpty) return false;
      _email = email;
      _username = (user['name'] ?? '').toString();
      _remixUserid = uid;
      _remixUserkey = key;
      await _persistAuth();
      _log('登录成功: $email');
      notifyListeners();
      refreshUserProfile(); // fire-and-forget：拉取服务端实际限额与已下载数
      return true;
    }
    _log('登录失败: $res');
    return false;
  }

  /// 发送注册验证码。对应 cmbook Zlibrary.sendCode
  Future<bool> sendCode(String email, String password, String name) async {
    final res = await _post(
      '/papi/user/verification/send-code',
      data: {
        'email': email,
        'password': password,
        'name': name,
        'rx': 215,
        'action': 'registration',
        'site_mode': 'books',
        'isSinglelogin': 1,
      },
    );
    return _isSuccess(res);
  }

  /// 提交验证码完成注册。rpc.php 返回不可靠，注册后用账号登录验证。
  /// 对应 cmbook ZlibraryRegister.run
  Future<bool> register(
    String email,
    String password,
    String name,
    String code,
  ) async {
    await _post(
      '/rpc.php',
      data: {
        'email': email,
        'password': password,
        'name': name,
        'verifyCode': code,
        'rx': 215,
        'action': 'registration',
        'redirectUrl': '',
        'isModa': true,
        'gg_json_mode': 1,
      },
    );
    return login(email, password); // 登录验证注册是否成功
  }

  Future<void> logout() async {
    _email = '';
    _username = '';
    _remixUserid = '';
    _remixUserkey = '';
    _serverDownloadsLimit = null;
    _serverDownloadsToday = 0;
    await _persistAuth();
    _log('退出登录');
    notifyListeners();
  }

  Future<void> _persistAuth() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_kEmail, _email);
    await prefs.setString(_kUsername, _username);
    await prefs.setString(_kRemixUserid, _remixUserid);
    await prefs.setString(_kRemixUserkey, _remixUserkey);
  }

  // -------------------- 搜索 --------------------

  /// 搜索图书。已登录自有账号用自有 token，否则轮询内置账号。
  /// 对应 cmbook BookSearch.run + _do_search。
  /// [extensions] 为格式筛选（多选，EPUB/PDF/...），null 或空=不筛选。
  Future<SearchResult<Book>> search(
    String message, {
    List<String>? extensions,
    String? languages,
    int? yearFrom,
    int? yearTo,
    int page = 1,
    int limit = 30,
  }) async {
    if (isLoggedIn) {
      final res = await _doSearch(
        message,
        extensions,
        languages,
        yearFrom,
        yearTo,
        page,
        limit,
        _remixUserid,
        _remixUserkey,
      );
      if (_isSuccess(res)) return _parseSearch(res);
      // 失败：区分地址不可用/限流/token 失效/真失败
      if (res['unavailable'] == true) {
        throw ZlibraryException('unavailable', '图书功能暂不可用，请等待恢复');
      }
      if (res['rate_limited'] == true) {
        throw ZlibraryException('rate_limited', '请求过于频繁，请稍后再试');
      }
      final useBuiltin = SettingsService().useBuiltinAccount;
      switch (await _verifyToken()) {
        case _TokenState.unavailable:
          throw ZlibraryException('unavailable', '图书功能暂不可用，请等待恢复');
        case _TokenState.invalid:
          // token 失效：清登录态；开关开则回退内置账号，否则提示重新登录
          await _clearSelfToken();
          if (!useBuiltin) {
            throw ZlibraryException('no_login', '登录已失效，请重新登录');
          }
          _log('自登 token 失效，回退内置账号搜索');
          break;
        case _TokenState.valid:
          if (!useBuiltin) {
            throw ZlibraryException('fail', '搜索失败，请稍后重试');
          }
          _log('自登搜索失败，回退内置账号');
          break;
      }
    }
    // 未登录：默认使用内置账号搜索（不受"使用内置账号"开关限制），以提升体验；
    // 也覆盖已登录自有账号失败且回退内置账号的情况。
    final res = await _searchWithBuiltin(
      message,
      extensions,
      languages,
      yearFrom,
      yearTo,
      page,
      limit,
    );
    if (res['unavailable'] == true) {
      throw ZlibraryException('unavailable', '图书功能暂不可用，请等待恢复');
    }
    if (res['rate_limited'] == true) {
      throw ZlibraryException('rate_limited', '请求过于频繁，请稍后再试');
    }
    if (!_isSuccess(res)) {
      throw ZlibraryException('no_account', '没有可用的内置账号');
    }
    return _parseSearch(res);
  }

  SearchResult<Book> _parseSearch(Map<String, dynamic> res) {
    final books = (res['books'] as List? ?? [])
        .whereType<Map>()
        .map((b) => Book.fromJson(Map<String, dynamic>.from(b)))
        .toList();
    final pag = (res['pagination'] as Map?) ?? {};
    final total = _asInt(pag['total_items']) ?? books.length;
    final totalPages = _asInt(pag['total_pages']) ?? 0;
    final current = _asInt(pag['current']) ?? 1;
    _log(
      '搜索分页: currentPage=$current, totalPages=$totalPages, '
      'total=$total, 返回${books.length}条, hasMore=${current < totalPages}',
    );
    return SearchResult<Book>(
      items: books,
      total: total,
      currentPage: current,
      totalPages: totalPages,
    );
  }

  // -------------------- 分类搜索（WebView 抓 HTML 解析）--------------------
  //
  // z-library /eapi/book/search 端点不支持分类过滤参数（实测 category/categories 等
  // 参数被服务端忽略），HTML 路由 /category/{id}/{slug} 被 Cloudflare JS 挑战拦截，
  // Dio 无法直抓。走 WebViewImageFetcher 单例（已在根树挂 1px 隐藏 WebView），由
  // webview 自动执行 JS 挑战通过 CF，再 runJavaScriptReturningResult 取
  // documentElement.outerHTML，用 html 包解析书籍卡片。

  /// 取分类页书的 eapi 匹配缓存（命中则无需再发搜索）。
  Book? categoryMatchCache(String bookId) => _categoryMatchCache[bookId];

  /// 写入分类页书的 eapi 匹配缓存（匹配成功后调用）。
  void setCategoryMatchCache(Book matched) =>
      _categoryMatchCache[matched.id] = matched;

  /// 按分类搜索图书（走 WebView 抓 HTML，CF 挑战由 webview 自动通过）。
  ///
  /// [category] 为选中的子分类；[keyword] 为空即纯分类浏览，非空即分类内搜索
  /// （URL：/category/{id}/{slug}/s/?q={keyword}&page={page}）。
  /// 失败抛 [ZlibraryException]（unavailable / fail）。
  Future<SearchResult<Book>> searchInCategory(
    BookCategory category, {
    String? keyword,
    int page = 1,
    int? yearFrom,
    int? yearTo,
    List<String>? languages,
    List<String>? extensions,
  }) async {
    if (_domain.isEmpty) {
      throw ZlibraryException('unavailable', '图书功能暂不可用，请等待恢复');
    }
    // 统一走 /s/ 搜索端点（支持 year/language/extension 过滤参数）。
    // `[]` 编码为 %5B%5D；过滤值原样拼入（traditional+chinese 的 + 不编码）。
    final buf = StringBuffer(
      'https://$_domain/category/${category.id}/${category.slug}/s/?page=$page',
    );
    final kw = keyword?.trim() ?? '';
    if (kw.isNotEmpty) buf.write('&q=${Uri.encodeQueryComponent(kw)}');
    if (yearFrom != null) buf.write('&yearFrom=$yearFrom');
    if (yearTo != null) buf.write('&yearTo=$yearTo');
    if (languages != null) {
      for (final lang in languages) {
        if (lang.isNotEmpty) buf.write('&languages%5B%5D=$lang');
      }
    }
    if (extensions != null) {
      for (final ext in extensions) {
        if (ext.isNotEmpty) buf.write('&extensions%5B%5D=$ext');
      }
    }
    final url = buf.toString();
    _log('分类搜索 WebView: $url');
    // WebView 抓取偶发失败（CF 挑战/网络抖动），自动重试 2 次（共 3 次尝试）。
    String? htmlStr;
    Object? lastError;
    for (var attempt = 1; attempt <= 3; attempt++) {
      try {
        final html = await WebViewImageFetcher().fetchHtml(url);
        if (html.isNotEmpty) {
          htmlStr = html;
          break;
        }
        lastError = StateError('分类搜索返回空 HTML');
      } catch (e) {
        lastError = e;
      }
      _log('分类搜索第 $attempt/3 次失败: $lastError');
      if (attempt < 3) {
        await Future.delayed(const Duration(milliseconds: 800));
      }
    }
    if (htmlStr == null) {
      _log('分类搜索 3 次均失败: $lastError');
      throw ZlibraryException('fail', '分类搜索失败，请稍后重试');
    }
    return _parseCategoryHtml(htmlStr, page);
  }

  /// 解析 z-library 分类页 HTML（书籍卡片 DOM 结构）。
  ///
  /// DOM 结构（用户实测 z-library 分类页）：
  /// - 卡片容器：`<div class="book-item resItemBoxBooks">`
  /// - 卡片元素：`<z-bookcard id="{bookId}" download="{下载URL}" year="..." language="..." extension="..." filesize="...">`
  /// - 封面：`<img src="...">`
  /// - 书名：`<div slot="title">...</div>`
  /// - 作者：`<div slot="authore">...</div>`
  /// bookHash 不在 z-bookcard 属性中，从 download URL（如 /dl/vALK9ZrE4R 或
  /// /book/{hash}/{slug}.html）或 a[href*="/book/"] 提取。
  SearchResult<Book> _parseCategoryHtml(String htmlStr, int page) {
    final doc = html_parser.parse(htmlStr);
    // 单一选择器 z-bookcard（用 .book-item 会与 z-bookcard 重复匹配）
    final rows = doc.querySelectorAll('z-bookcard');
    final books = <Book>[];
    final seenIds = <String>{};
    for (final r in rows) {
      try {
        final book = _parseBookRow(r);
        if (book != null && book.id.isNotEmpty && !seenIds.contains(book.id)) {
          seenIds.add(book.id);
          books.add(book);
        }
      } catch (_) {}
    }
    // 调试：解析到 0 条时输出 HTML 片段，辅助定位 DOM 变化
    if (books.isEmpty) {
      _log('分类页解析到 0 条，HTML 长度=${htmlStr.length}');
      _log(
        'HTML 前 800 字: ${htmlStr.length > 800 ? htmlStr.substring(0, 800) : htmlStr}',
      );
    } else {
      _log(
        '分类页解析到 ${books.length} 条，前两条: '
        '${books.take(2).map((b) => '${b.title}(id=${b.id},hash=${b.hash})').join(", ")}',
      );
    }
    // 解析分页（z-library 桌面端 .pagination 含总页数；老前端是数字 <a>，
    // 新前端可能用 href?page=N，两种都试）。
    var totalPages = 0;
    final pagLinks = doc.querySelectorAll('.pagination a');
    for (final a in pagLinks) {
      final txt = int.tryParse(a.text.trim());
      if (txt != null && txt > totalPages) totalPages = txt;
    }
    // 兜底：取不到数字时按 href 里的 page= 参数最大值
    if (totalPages == 0) {
      for (final a in pagLinks) {
        final href = a.attributes['href'] ?? '';
        final m = RegExp(r'page=(\d+)').firstMatch(href);
        final p = m == null ? null : int.tryParse(m.group(1)!);
        if (p != null && p > totalPages) totalPages = p;
      }
    }
    // 仍取不到 totalPages：按本页条数推断（每页最多 50 条）。
    // 满页 = 还有下一页（totalPages = page+1 使 hasMore 为 true）；
    // 不足 = 末页（totalPages = page 使 hasMore 为 false）。
    const pageSize = 50;
    if (totalPages == 0) {
      totalPages = books.length >= pageSize ? page + 1 : page;
    }
    final total = books.isNotEmpty && totalPages > 0
        ? totalPages * pageSize
        : books.length;
    _log(
      '分类分页: page=$page, totalPages=$totalPages, '
      'pagination链接数=${pagLinks.length}, 返回${books.length}条',
    );
    return SearchResult<Book>(
      items: books,
      total: total,
      currentPage: page,
      totalPages: totalPages,
    );
  }

  // -------------------- 分类目录（/categories 页动态抓取）--------------------

  /// 抓取 `/categories` 页填充 [BookCategories.groups]（主分类 -> 子分类两级树）。
  ///
  /// 走 WebView 抓 HTML（CF 挑战由 webview 自动通过）。成功后写回 groups、
  /// 持久化到 SharedPreferences、notifyListeners。失败抛 [ZlibraryException]。
  /// [force] = true 强制重新抓取（忽略已有缓存）。
  Future<List<BookCategoryGroup>> fetchCategories({bool force = false}) async {
    if (!force && BookCategories.groups.isNotEmpty) {
      return BookCategories.groups;
    }
    if (_domain.isEmpty) {
      throw ZlibraryException('unavailable', '图书功能暂不可用，请等待恢复');
    }
    final url = 'https://$_domain/categories';
    _log('抓取分类目录: $url');
    String? htmlStr;
    Object? lastError;
    for (var attempt = 1; attempt <= 3; attempt++) {
      try {
        final html = await WebViewImageFetcher().fetchHtml(url);
        if (html.isNotEmpty) {
          htmlStr = html;
          break;
        }
        lastError = StateError('分类页返回空 HTML');
      } catch (e) {
        lastError = e;
      }
      _log('分类页第 $attempt/3 次失败: $lastError');
      if (attempt < 3) {
        await Future.delayed(const Duration(milliseconds: 800));
      }
    }
    if (htmlStr == null) {
      _log('分类页 3 次均失败: $lastError');
      throw ZlibraryException('fail', '分类目录加载失败，请稍后重试');
    }
    final groups = _parseCategoriesHtml(htmlStr);
    if (groups.isEmpty) {
      _log('分类页解析到 0 组，HTML 长度=${htmlStr.length}');
      throw ZlibraryException('fail', '分类目录解析失败');
    }
    BookCategories.groups = groups;
    _persistCategories(); // fire-and-forget
    _log('分类目录更新: ${groups.length} 组');
    notifyListeners();
    return groups;
  }

  /// 解析 `/categories` 页 HTML。
  ///
  /// DOM 结构：每个 `.subcategories-container` 为一个主分类块，
  /// `.category-name a` 文本 = 主分类名（组标题，翻译），
  /// `ul li.subcategory-name a` = 子分类（href 提 id/slug，文本翻译保留计数）。
  /// 主分类本身作为首个子项「全部」加入（id 取主分类 href，slug 用名称 slugify）。
  List<BookCategoryGroup> _parseCategoriesHtml(String htmlStr) {
    final doc = html_parser.parse(htmlStr);
    final containers = doc.querySelectorAll('.subcategories-container');
    final groups = <BookCategoryGroup>[];
    for (final c in containers) {
      // 主分类名：.category-name 下的 a（兜底 .category-name 本身即 a）
      final cn = c.querySelector('.category-name');
      String? mainName;
      String? mainHref;
      if (cn != null) {
        final a = cn.querySelector('a') ?? (cn.localName == 'a' ? cn : null);
        if (a != null) {
          mainName = a.text.trim();
          mainHref = a.attributes['href'];
        } else {
          mainName = cn.text.trim();
        }
      }
      if (mainName == null || mainName.isEmpty) continue;
      final title = BookCategories.translate(mainName);

      // 子分类：li.subcategory-name 下的 a（兜底 .subcategory-name a）
      var subAs = c.querySelectorAll('li.subcategory-name a');
      if (subAs.isEmpty) subAs = c.querySelectorAll('.subcategory-name a');
      final children = <BookCategory>[];

      // 主分类作为「全部」子项
      final mainId = _categoryIdFromHref(mainHref);
      if (mainId != null) {
        children.add(BookCategory(mainId, _slugify(mainName), '全部'));
      }

      for (final a in subAs) {
        final name = a.text.trim();
        final href = a.attributes['href'] ?? '';
        final id = _categoryIdFromHref(href);
        final slug = _categorySlugFromHref(href);
        if (id == null || slug.isEmpty) continue;
        children.add(
          BookCategory(
            id,
            slug,
            BookCategories.translate(name, context: mainName),
          ),
        );
      }
      if (children.isNotEmpty) {
        groups.add(BookCategoryGroup(title, children));
      }
    }
    return groups;
  }

  /// 从分类 href 提取数字 id（`/category/40/Architecture` -> 40；`/category/1` -> 1）。
  int? _categoryIdFromHref(String? href) {
    if (href == null || href.isEmpty) return null;
    final m = RegExp(r'/category/(\d+)').firstMatch(href);
    return m == null ? null : int.tryParse(m.group(1)!);
  }

  /// 从分类 href 提取 slug（`/category/40/Architecture` -> `Architecture`）。
  /// 主分类 href（`/category/1`，无 slug 段）返回空。
  String _categorySlugFromHref(String? href) {
    if (href == null || href.isEmpty) return '';
    final m = RegExp(r'/category/\d+/([^/?#]+)').firstMatch(href);
    return m == null ? '' : m.group(1)!;
  }

  /// 把主分类英文名转成 URL slug。slug 为展示用，服务端按 id 路由，内容无关紧要。
  String _slugify(String name) {
    var s = name.replaceAll('&', 'and');
    s = s.replaceAll(RegExp(r'[^A-Za-z0-9]+'), '-');
    s = s.replaceAll(RegExp(r'-+'), '-');
    s = s.replaceAll(RegExp(r'^-|-$'), '');
    return s.isEmpty ? 'all' : s;
  }

  /// 从单个 `z-bookcard` 元素解析 [Book]。
  ///
  /// z-bookcard 自带属性：id（bookId 数字）、year、language、extension、filesize、
  /// download（下载 URL，含 hash 片段，如 /dl/vALK9ZrE4R 或 /book/{hash}/{slug}.html）。
  /// bookHash 无专门属性，从 download 或详情链接 URL 中提取。
  Book? _parseBookRow(dynamic rowEl) {
    final row = rowEl as html_element.Element;
    String? cover;
    String? title;
    String? author;
    String? year;
    String? language;
    String? extension;
    String? filesizeString;
    String? id;
    String? hash;

    // id：z-bookcard 的 id 属性（数字 bookId）
    final idAttr = row.attributes['id'];
    if (idAttr != null && idAttr.isNotEmpty && int.tryParse(idAttr) != null) {
      id = idAttr;
    }

    // 元数据：z-bookcard 自带属性 year / language / extension / filesize
    final yearAttr = row.attributes['year'];
    if (yearAttr != null && yearAttr.isNotEmpty) year = yearAttr;
    final langAttr = row.attributes['language'];
    if (langAttr != null && langAttr.isNotEmpty) language = langAttr;
    final extAttr = row.attributes['extension'];
    if (extAttr != null && extAttr.isNotEmpty) extension = extAttr;
    final fsAttr = row.attributes['filesize'];
    if (fsAttr != null && fsAttr.isNotEmpty) filesizeString = fsAttr;

    // hash：分类页 z-bookcard 不暴露 eapi hash（termshash 为空），
    // 改用 download 属性（如 "/dl/xnl1dlgGRJ"）归一为 "dl/{slug}" 存入 hash；
    // 下载侧 getDownloadLink 检测到 dl slug 走 WebView 解析真实下载 URL。
    final dlAttr = row.attributes['download'] ?? '';
    if (dlAttr.isNotEmpty) {
      final m = RegExp(
        r'(?:https?://[^/]+)?/dl/([0-9a-zA-Z_-]+)',
      ).firstMatch(dlAttr);
      if (m != null) {
        hash = 'dl/${m.group(1)}';
      } else {
        hash = dlAttr;
      }
    }
    // 兼容：从详情链接补充 hash（仅 dl 属性缺失时）
    if (hash == null || hash.isEmpty) {
      final link = row.querySelector('a[href*="/book/"]');
      if (link != null) {
        final h = link.attributes['href'] ?? '';
        final m = RegExp(
          r'/book/([0-9a-zA-Z_-]{6,16})(?:/|\.|$)',
        ).firstMatch(h);
        if (m != null) hash = m.group(1);
        final m2 = RegExp(r'/book/\d+/([0-9a-fA-F]{16,})').firstMatch(h);
        if (m2 != null && (hash == null || hash.isEmpty)) hash = m2.group(1);
      }
    }

    // 书名：div[slot="title"]
    final titleEl = row.querySelector('[slot="title"]');
    title = titleEl?.text.trim();
    if (title == null || title.isEmpty) return null;

    // 封面：img
    final img = row.querySelector('img');
    if (img != null) {
      cover = img.attributes['src'] ?? img.attributes['data-src'];
    }
    // 作者：div[slot="author"]（旧版拼为 authore，两个都兼容）
    final authorEl = row.querySelector('[slot="author"], [slot="authore"]');
    if (authorEl != null) author = authorEl.text.trim();

    return Book(
      id: id ?? '',
      hash: hash ?? '',
      title: title,
      author: author,
      cover: cover,
      year: year,
      language: language,
      extension: extension,
      filesizeString: filesizeString,
      readOnlineUrl: rowEl.attributes['readOnlineUrl'],
    );
  }

  Future<Map<String, dynamic>> _searchWithBuiltin(
    String message,
    List<String>? extensions,
    String? languages,
    int? yearFrom,
    int? yearTo,
    int page,
    int limit,
  ) async {
    // 优先复用缓存的内置 token
    if (_builtinUserid != null && _builtinUserkey != null) {
      final res = await _doSearch(
        message,
        extensions,
        languages,
        yearFrom,
        yearTo,
        page,
        limit,
        _builtinUserid!,
        _builtinUserkey!,
      );
      if (_isSuccess(res)) return res;
      // 地址不可用/限流：直接返回（停止轮询，避免加剧 429 / 同地址都失败）
      if (res['unavailable'] == true || res['rate_limited'] == true) return res;
      _builtinUserid = _builtinUserkey = null;
    }
    // 轮询内置账号登录
    for (final acc in kBuiltinAccounts) {
      final token = await _loginForToken(acc.email, acc.password);
      if (token == null) {
        // 登录即不可用：全候选地址不可用，停止轮询
        if (_unavailable) return {'success': false, 'unavailable': true};
        continue;
      }
      _builtinUserid = token.userid;
      _builtinUserkey = token.userkey;
      final res = await _doSearch(
        message,
        extensions,
        languages,
        yearFrom,
        yearTo,
        page,
        limit,
        token.userid,
        token.userkey,
      );
      if (_isSuccess(res)) return res;
      if (res['unavailable'] == true) return res; // 全候选地址不可用，停止轮询
      if (res['rate_limited'] == true) return res; // 限流，停止轮询避免加剧 429
      // 其余失败：试下一个账号（token 若失效，下次 _loginForToken 自动重登）
    }
    return {'success': false};
  }

  Future<Map<String, dynamic>> _doSearch(
    String message,
    List<String>? extensions,
    String? languages,
    int? yearFrom,
    int? yearTo,
    int page,
    int limit,
    String userid,
    String userkey,
  ) async {
    final data = <String, dynamic>{
      'message': message,
      'page': page,
      'limit': limit,
    };
    if (extensions != null && extensions.isNotEmpty) {
      data['extensions[]'] = extensions;
    }
    if (languages != null && languages.isNotEmpty) {
      data['languages[]'] = languages;
    }
    if (yearFrom != null) {
      data['yearFrom'] = yearFrom;
      data['yearTo'] = yearTo ?? yearFrom;
    }
    return _post(
      '/eapi/book/search',
      data: data,
      cookies: _cookies(userid, userkey),
    );
  }

  // -------------------- 下载链接 --------------------

  /// 获取下载链接。已登录自有账号用自有 token，否则按 round-robin 起点轮询内置账号。
  /// 失败按原因抛 ZlibraryException：quota_exceeded / no_login / unavailable / no_account / fail。
  /// 对应 cmbook Zlibrary.getDownloadLink + BookDownload._download_with_builtin_account。
  /// [startIndex] 用于内置账号轮询起点（按已用计数均匀分散到各账号）。
  ///
  /// 兼容：[bookHash] 不是 eapi hash（6 位 hex）而是 `/dl/{slug}` 的 slug 形式
  /// 或 `dl/{slug}`（来自分类页 z-bookcard download 属性）时，eapi 端点不可用，
  /// 改走 WebView 加载短链取重定向后的真实 CDN 下载地址。
  Future<DownloadLink> getDownloadLink(
    String bookId,
    String bookHash, {
    int startIndex = 0,
  }) async {
    // 分类页来源：hash 是 /dl/{slug} 或纯 slug（非 6 位 hex eapi hash）
    if (_isDlSlug(bookHash)) {
      _log('检测到 dl slug，走 WebView 解析下载: $bookHash');
      return _getDownloadLinkByDlSlug(bookId, bookHash);
    }
    final useBuiltin = SettingsService().useBuiltinAccount;
    if (isLoggedIn) {
      final link = await _fetchDownloadLink(
        bookId,
        bookHash,
        _remixUserid,
        _remixUserkey,
      );
      if (link != null) return link;
      // 失败：区分额度用完/token 失效/地址不可用/真失败
      switch (await _diagnoseDownloadFailure()) {
        case 'quota_exceeded':
          throw ZlibraryException('quota_exceeded', '账号今日额度已用完');
        case 'unavailable':
          throw ZlibraryException('unavailable', '图书功能暂不可用，请等待恢复');
        case 'no_login':
          await _clearSelfToken();
          throw ZlibraryException('no_login', '登录已失效，请重新登录');
        default:
          if (!useBuiltin) {
            throw ZlibraryException('fail', '获取下载链接失败，请稍后重试');
          }
          _log('自登取链接失败，回退内置账号');
      }
    } else if (!useBuiltin) {
      // 关闭内置账号且未登录：无可用账号
      throw ZlibraryException('no_login', '请先登录账号');
    }
    // 内置账号轮询
    final n = kBuiltinAccounts.length;
    var anyQuotaExceeded = false;
    for (var i = 0; i < n; i++) {
      final acc = kBuiltinAccounts[(startIndex + i) % n];
      final token = await _loginForToken(acc.email, acc.password);
      if (token == null) {
        // 登录即不可用：全候选地址不可用，立即返回（与搜索一致，不遍历全部账号）
        if (_unavailable) {
          throw ZlibraryException('unavailable', '图书功能暂不可用，请等待恢复');
        }
        continue;
      }
      final link = await _fetchDownloadLink(
        bookId,
        bookHash,
        token.userid,
        token.userkey,
      );
      if (link != null) return link;
      if (_quotaExceeded) {
        // 各账号额度独立，记录后试下一个
        anyQuotaExceeded = true;
        continue;
      }
      if (_unavailable) {
        throw ZlibraryException('unavailable', '图书功能暂不可用，请等待恢复');
      }
      // 其余失败：试下一个账号
    }
    // 全部内置账号失败
    if (anyQuotaExceeded) {
      throw ZlibraryException('quota_exceeded', '账号今日额度已用完');
    }
    throw ZlibraryException('no_account', '没有可用的内置账号');
  }

  Future<DownloadLink?> _fetchDownloadLink(
    String bookId,
    String bookHash,
    String userid,
    String userkey,
  ) async {
    _quotaExceeded = false;
    final res = await _get(
      '/eapi/book/$bookId/$bookHash/file',
      cookies: _cookies(userid, userkey),
    );
    if (res['unavailable'] == true) return null; // _unavailable 已由 _send 置位
    if (!_isSuccess(res) || res['file'] is! Map) return null;
    final file = res['file'] as Map;
    if (!_isTruthy(file['allowDownload'])) {
      // 额度用完：disallowDownloadMessage 含 "limit"（z-library 免费账号 10 本/日）
      final msg = (file['disallowDownloadMessage'] ?? '')
          .toString()
          .toLowerCase();
      if (msg.contains('limit')) _quotaExceeded = true;
      return null;
    }
    final ddl = (file['downloadLink'] ?? '').toString();
    if (ddl.isEmpty) return null;
    var filename = (file['description'] ?? '').toString();
    final author = file['author'];
    if (author != null) filename += ' ($author)';
    filename += '.${file['extension'] ?? 'epub'}';
    final headers = <String, String>{'User-Agent': _browserUa};
    try {
      headers['authority'] = ddl.split('/')[2];
    } catch (_) {}
    return DownloadLink(filename: filename, url: ddl, headers: headers);
  }

  /// 判断 [bookHash] 是否是 z-library `/dl/{slug}` 下载短链 slug，
  /// 而非 eapi 的 6 位 hex hash（如 "0ce60f"）。
  /// 规则：含 `/dl/` 前缀、或长度 != 6、或非纯 hex，视为 dl slug。
  bool _isDlSlug(String bookHash) {
    if (bookHash.isEmpty) return false;
    return bookHash.startsWith('dl/') || bookHash.contains('/dl/');
  }

  /// 分类页 /dl/{slug} 短链：用临时 Dio 跟随重定向链，从最终的 URL 取真实 CDN 地址。
  /// `_dio` 主请求禁重定向（用于 eapi），这里临时构造一个 Dio 走 followRedirects。
  /// 登录 cookie 不需要（z-library dl 短链免登录靠 IP 限额），仅带浏览器 UA 头。
  /// 若 Dio 被 CF 拦（返回 HTML 挑战页），回退到 WebView 解析兜底。
  Future<DownloadLink> _getDownloadLinkByDlSlug(
    String bookId,
    String bookHash,
  ) async {
    var slug = bookHash;
    final m = RegExp(r'/?dl/([0-9a-zA-Z_-]+)').firstMatch(slug);
    if (m != null) slug = m.group(1)!;
    final shortUrl = 'https://$_domain/dl/$slug';
    // 临时构造跟随重定向的 Dio
    final dio = Dio(
      BaseOptions(
        connectTimeout: const Duration(seconds: 15),
        receiveTimeout: const Duration(seconds: 30),
        followRedirects: true,
        maxRedirects: 5,
        validateStatus: (_) => true,
        headers: {'User-Agent': _browserUa},
      ),
    );
    try {
      // 带 z-library 登录 cookie（内置/自登均可，提高成功率）
      final cookies = isLoggedIn ? _cookies(_remixUserid, _remixUserkey) : null;
      final resp = await dio.get<dynamic>(
        shortUrl,
        options: Options(
          headers: cookies != null && cookies.isNotEmpty
              ? {
                  'Cookie': cookies.entries
                      .map((e) => '${e.key}=${e.value}')
                      .join('; '),
                }
              : null,
        ),
      );
      // 跟随后 final URL
      final realUrl = resp.realUri.toString();
      // 防止 CF 挑战页（被拦到 HTML）：判定 URL host 是否在 CDN
      final isCdn = realUrl != shortUrl && Uri.parse(realUrl).host != _domain;
      if (isCdn) {
        _log('解析下载链接成功(dio): $realUrl');
        final headers = <String, String>{'User-Agent': _browserUa};
        try {
          headers['authority'] = realUrl.split('/')[2];
        } catch (_) {}
        return DownloadLink(
          filename: '$bookId.bin',
          url: realUrl,
          headers: headers,
        );
      }
      _log('Dio 未能跨域到 CDN，realUrl=$realUrl，回退 WebView');
    } catch (e) {
      _log('Dio 解析下载链接失败: $e');
    } finally {
      dio.close();
    }
    // 兜底：WebView 拦截重定向
    try {
      final realUrl = await WebViewImageFetcher().resolveDownloadUrl(shortUrl);
      if (realUrl.isNotEmpty) {
        _log('解析下载链接成功(webview): $realUrl');
        final headers = <String, String>{'User-Agent': _browserUa};
        try {
          headers['authority'] = realUrl.split('/')[2];
        } catch (_) {}
        return DownloadLink(
          filename: '$bookId.bin',
          url: realUrl,
          headers: headers,
        );
      }
    } catch (e) {
      _log('WebView 兜底解析失败: $e');
    }
    throw ZlibraryException('fail', '获取下载链接失败，请稍后重试');
  }

  /// 复校 token 是否仍有效（运行时 API 失败时调用，区分 token 失效 vs 真失败）。
  /// 返回 valid=token 有效（按真失败处理）/ invalid=token 失效（需重新登录）/ unavailable=地址不可用。
  /// 对应 cmbook Zlibrary.verifyToken。
  Future<_TokenState> _verifyToken() async {
    final res = await _get(
      '/eapi/user/profile',
      cookies: _cookies(_remixUserid, _remixUserkey),
    );
    if (res['unavailable'] == true) return _TokenState.unavailable;
    if (_isSuccess(res)) return _TokenState.valid;
    return _TokenState.invalid;
  }

  /// 清除自有账号登录态（token 失效时调用，提示用户重新登录）。
  Future<void> _clearSelfToken() async {
    _remixUserid = '';
    _remixUserkey = '';
    _serverDownloadsLimit = null;
    _serverDownloadsToday = 0;
    await _persistAuth();
    _log('自登 token 失效，已清登录态');
    notifyListeners();
  }

  /// 诊断下载链接获取失败的原因（额度用完优先于 token 复校）。
  /// 返回 'quota_exceeded' / 'unavailable' / 'no_login' / 'fail'。
  Future<String> _diagnoseDownloadFailure() async {
    if (_quotaExceeded) return 'quota_exceeded';
    if (_unavailable) return 'unavailable';
    switch (await _verifyToken()) {
      case _TokenState.unavailable:
        return 'unavailable';
      case _TokenState.invalid:
        return 'no_login';
      case _TokenState.valid:
        return 'fail';
    }
  }

  // -------------------- 每日限额（对应 cmbook reserve/release）--------------------

  /// 今日内置账号已下载数（跨日归零）
  int get builtinCountToday {
    final today = _today();
    final d = _builtinCountCache['date'] as String? ?? '';
    return d == today ? (_builtinCountCache['count'] as int? ?? 0) : 0;
  }

  /// 今日自有账号已下载数（纯服务端值，来自 /eapi/user/profile；不使用本地计数）
  int get loggedCountToday => isLoggedIn ? _serverDownloadsToday : 0;

  /// 预留一个内置下载名额（计数+1）。超限返回 null；成功返回轮询起点 index。
  int? reserveBuiltinDownload() {
    final today = _today();
    var count = (_builtinCountCache['date'] == today
        ? (_builtinCountCache['count'] as int? ?? 0)
        : 0);
    if (count >= builtinDailyLimit) return null;
    count++;
    _writeBuiltinCount(today, count);
    return (count - 1) % kBuiltinAccounts.length;
  }

  void releaseBuiltinDownload() {
    final today = _today();
    if (_builtinCountCache['date'] != today) return;
    final count = _builtinCountCache['count'] as int? ?? 0;
    if (count > 0) _writeBuiltinCount(today, count - 1);
  }

  /// 自登账号纯服务端判定：仅按服务端 downloads_today 判断是否还有额度，不自增本地计数。
  /// 实际额度由服务端在下载链接阶段强制（quota_exceeded）；此处仅做前置拦截。
  bool reserveLoggedDownload() {
    if (!isLoggedIn) return false;
    if (_serverDownloadsToday >= (_serverDownloadsLimit ?? loggedDailyLimit)) {
      return false;
    }
    return true;
  }

  /// 自登账号纯服务端判定：不维护本地计数，无需释放。
  void releaseLoggedDownload() {}

  /// 拉取自有账号 profile，取服务端每日下载限额与已下载数。
  /// 自登账号纯服务端判定：不维护本地计数，每次重启 App 后由此方法重新拉取最新值。
  /// 失败静默保留旧值（_log）。对应 z-library /eapi/user/profile。
  Future<void> refreshUserProfile() async {
    if (!isLoggedIn) return;
    final res = await _get(
      '/eapi/user/profile',
      cookies: _cookies(_remixUserid, _remixUserkey),
    );
    if (!_isSuccess(res) || res['user'] is! Map) {
      _log('拉取 profile 失败: $res');
      return;
    }
    final user = res['user'] as Map;
    _serverDownloadsToday = _asInt(user['downloads_today']) ?? 0;
    _serverDownloadsLimit = _asInt(user['downloads_limit']);
    _log(
      'profile: downloads_today=$_serverDownloadsToday, '
      'downloads_limit=$_serverDownloadsLimit',
    );
    notifyListeners();
  }

  // -------------------- HTTP 基础（对应 cmbook __makePostRequest/__makeGetRequest）--------------------

  Map<String, String> _cookies(String userid, String userkey) => {
    'siteLanguageV2': 'en',
    'remix_userid': userid,
    'remix_userkey': userkey,
  };

  Future<Map<String, dynamic>> _post(
    String path, {
    Map<String, dynamic>? data,
    Map<String, String>? cookies,
  }) => _send('POST', path, data: data, cookies: cookies);

  Future<Map<String, dynamic>> _get(
    String path, {
    Map<String, dynamic>? params,
    Map<String, String>? cookies,
  }) => _send('GET', path, params: params, cookies: cookies);

  /// 候选感知请求：遍历候选域名，对每域名做 429/5xx 退避重试；
  /// 连接异常（DNS/超时/重置）与 404（域名非 z-library 主机）都切下一个候选；
  /// 重定向到新域名 -> 更新+加候选+在新域名重试一次（followed 防循环）。
  /// 全候选连接失败/全 404 -> 标记 unavailable 返回 {success:false,unavailable:true}。
  /// 对应 cmbook Zlibrary.__request_with_retry + __makePostRequest/__makeGetRequest。
  Future<Map<String, dynamic>> _send(
    String method,
    String path, {
    Map<String, dynamic>? data,
    Map<String, dynamic>? params,
    Map<String, String>? cookies,
  }) async {
    var followed = false;
    DioException? lastConnError;
    var any404 = false;
    for (;;) {
      final order = _candidateOrder();
      var restartForRedirect = false;
      for (final domain in order) {
        try {
          var attempt = 0;
          while (true) {
            _log('$method https://$domain$path');
            final Response<dynamic> resp;
            if (method == 'POST') {
              resp = await _dio.post(
                'https://$domain$path',
                data: data,
                options: Options(
                  headers: _headers(cookies),
                  contentType: Headers.formUrlEncodedContentType,
                ),
              );
            } else {
              resp = await _dio.get(
                'https://$domain$path',
                queryParameters: params,
                options: Options(headers: _headers(cookies)),
              );
            }
            final status = resp.statusCode;
            // 404：域名非 z-library 主机，切下一候选
            if (status == 404) {
              any404 = true;
              _log('节点 $domain 返回 404（非 z-library 主机），切下一候选');
              break;
            }
            // 重定向到新域名：更新+加候选+在新域名重试一次
            final redirected = _maybeRedirect(
              status,
              resp.headers.value('location'),
            );
            if (redirected != null && !followed) {
              _domain = redirected;
              await _persistDomain();
              _addCandidate(redirected);
              _log('域名重定向 -> $_domain');
              followed = true;
              restartForRedirect = true;
              break;
            }
            // 429/5xx：同域名退避重试
            if (status != null && _kRetryStatus.contains(status)) {
              if (attempt >= _kMaxRetries) {
                if (domain != _domain) {
                  _domain = domain;
                  await _persistDomain();
                }
                _setUnavailable(false);
                return {
                  'success': false,
                  'rate_limited': true,
                  'error': '请求过于频繁，请稍后再试',
                };
              }
              await _retryWait(resp, attempt);
              attempt++;
              continue;
            }
            // 业务响应（含已跟随重定向/非重定向）
            if (domain != _domain) {
              _domain = domain;
              await _persistDomain();
            }
            _setUnavailable(false);
            return _asJsonMap(resp.data);
          }
          if (restartForRedirect) break; // 重启外层，新域名优先
          // 否则 404 跳出内层 -> 试下一候选
        } on DioException catch (e) {
          // 连接失败（DNS/超时/重置）：切下一候选
          lastConnError = e;
          _log('节点 $domain 不可达: $e，切下一候选');
          continue;
        }
      }
      if (restartForRedirect) continue; // 用新 _domain 重算候选顺序重试
      break; // 全候选耗尽
    }
    // 全候选连接失败 或 全 404
    _setUnavailable(true);
    _log('所有 zlibrary 节点不可达或 404（any404=$any404, err=$lastConnError）');
    return {'success': false, 'unavailable': true, 'error': '图书功能暂不可用'};
  }

  /// 429/5xx 退避：优先 Retry-After，否则指数退避 2/4/8s，上限 8s。
  Future<void> _retryWait(Response<dynamic> resp, int attempt) async {
    var ms = (1 << (attempt + 1)) * 1000; // 2s, 4s, 8s
    final ra = resp.headers.value('retry-after');
    if (ra != null) {
      final v = int.tryParse(ra);
      if (v != null) ms = v * 1000;
    }
    if (ms > 8000) ms = 8000;
    await Future.delayed(Duration(milliseconds: ms));
  }

  /// 301/302/303/307/308 且 Location 指向新域名 -> 返回新域名；否则 null
  String? _maybeRedirect(int? status, String? location) {
    if (status == null || ![301, 302, 303, 307, 308].contains(status))
      return null;
    if (location == null || location.isEmpty) return null;
    final host = Uri.tryParse(location)?.host;
    if (host != null && host.isNotEmpty && host != _domain) return host;
    return null;
  }

  Map<String, String> _headers(Map<String, String>? cookies) {
    final h = <String, String>{
      'User-Agent': _browserUa,
      'accept':
          'text/html,application/xhtml+xml,application/xml;q=0.9,image/avif,image/webp,image/apng,*/*;q=0.8,application/signed-exchange;v=b3;q=0.7',
      'accept-language': 'en-US,en;q=0.9',
    };
    if (cookies != null && cookies.isNotEmpty) {
      h['Cookie'] = cookies.entries
          .map((e) => '${e.key}=${e.value}')
          .join('; ');
    }
    return h;
  }

  bool _isSuccess(dynamic res) => res is Map && _isTruthy(res['success']);

  /// z-library eapi 的成功/允许标志返回的是整数 1 而非布尔 true
  /// （如 success、allowDownload），需按真值判断，对应 Python if res.get('success')。
  bool _isTruthy(dynamic v) => v == true || v == 1;

  Map<String, dynamic> _asJsonMap(dynamic data) {
    if (data is Map<String, dynamic>) return data;
    if (data is Map) return Map<String, dynamic>.from(data);
    if (data is String && data.isNotEmpty) {
      try {
        final decoded = jsonDecode(data);
        if (decoded is Map) return Map<String, dynamic>.from(decoded);
      } catch (_) {}
    }
    return {};
  }

  int? _asInt(dynamic v) {
    if (v == null) return null;
    if (v is int) return v;
    if (v is double) return v.toInt();
    return int.tryParse('$v');
  }

  /// 内置账号登录取 token（仅内存，不持久化）
  Future<_Token?> _loginForToken(String email, String password) async {
    final res = await _post(
      '/eapi/user/login',
      data: {'email': email, 'password': password},
    );
    if (_isSuccess(res) && res['user'] is Map) {
      final user = res['user'] as Map;
      final uid = (user['id'] ?? '').toString();
      final key = (user['remix_userkey'] ?? '').toString();
      if (uid.isNotEmpty && key.isNotEmpty) return _Token(uid, key);
    }
    return null;
  }

  // -------------------- 计数持久化 --------------------

  Map<String, dynamic> _builtinCountCache = {};

  Future<void> _loadCounts() async {
    final prefs = await SharedPreferences.getInstance();
    _builtinCountCache = _decode(prefs.getString(_kBuiltinCount));
  }

  void _writeBuiltinCount(String today, int count) {
    _builtinCountCache = {'date': today, 'count': count};
    final raw = jsonEncode(_builtinCountCache);
    SharedPreferences.getInstance().then(
      (p) => p.setString(_kBuiltinCount, raw),
    );
  }

  Map<String, dynamic> _decode(String? raw) {
    if (raw == null || raw.isEmpty) return {};
    try {
      final d = jsonDecode(raw);
      if (d is Map) return Map<String, dynamic>.from(d);
    } catch (_) {}
    return {};
  }

  /// 解析持久化的候选节点列表（JSON 数组），异常/空返回 []。
  List<String> _decodeCandidates(String? raw) {
    if (raw == null || raw.isEmpty) return [];
    try {
      final d = jsonDecode(raw);
      if (d is List) {
        return d
            .map((e) => e.toString().trim())
            .where((e) => e.isNotEmpty)
            .toList();
      }
    } catch (_) {}
    return [];
  }

  String _today() {
    final now = DateTime.now();
    String two(int v) => v.toString().padLeft(2, '0');
    return '${now.year}-${two(now.month)}-${two(now.day)}';
  }

  // -------------------- 多节点容灾（对应 cmbook StartupCheckThread + ZlibraryHealthCheckThread）--------------------

  /// 应用云端候选节点：归一化 + 并发探测选最优写回 _domain + 写完整候选列表。
  /// 由 RemoteConfigService 拉到云端 zlibrary_url 后调用（启动检测，不阻塞 UI）。
  /// 全不可用仍写候选列表（供定时检测与运行时切换），并标记 unavailable。
  Future<void> applyCloudCandidates(Object? cloud) async {
    final candidates = _normalizeCandidates(cloud);
    if (candidates.isEmpty) return;
    _log('应用云端候选节点: $candidates');
    final best = await _pickBestCandidate(candidates);
    if (candidates != _candidates) {
      _candidates = candidates;
      await _persistCandidates();
    }
    if (best != null && best != _domain) {
      _domain = best;
      await _persistDomain();
    }
    _setUnavailable(best == null);
    _log('启动探测完成: best=$best, unavailable=${best == null}');
    notifyListeners();
  }

  /// 归一化候选列表（去重保序；单字符串 -> 单元素列表）。
  List<String> _normalizeCandidates(Object? raw) {
    final List items;
    if (raw is String) {
      items = [raw];
    } else if (raw is List) {
      items = raw;
    } else {
      return [];
    }
    final seen = <String>{};
    final result = <String>[];
    for (final item in items) {
      final d = item.toString().trim();
      if (d.isNotEmpty && !seen.contains(d)) {
        seen.add(d);
        result.add(d);
      }
    }
    return result;
  }

  /// 并发探测候选节点，返回延迟最低的可用域名（无 scheme）。
  /// 探测到延迟 < 3s 的可用节点即提前返回，不再等其余候选；全不可用返回 null。
  /// 对应 cmbook StartupCheckThread._pick_best_zlibrary_url。
  Future<String?> _pickBestCandidate(List<String> candidates) async {
    if (candidates.isEmpty) return null;
    final completer = Completer<String?>();
    final collected = <_Probe>[];
    var remaining = candidates.length;
    for (final c in candidates) {
      _probeUrl(c).then((r) {
        if (completer.isCompleted) return;
        if (r != null) {
          collected.add(r);
          if (r.latency < 3.0) {
            completer.complete(r.domain); // <3s 提前返回
            return;
          }
        }
        remaining--;
        if (remaining == 0) {
          if (collected.isEmpty) {
            completer.complete(null);
          } else {
            collected.sort((a, b) => a.latency.compareTo(b.latency));
            completer.complete(collected.first.domain);
          }
        }
      });
    }
    return completer.future;
  }

  /// 探测单个节点可用性，跟随重定向，返回 (最终落地域名, 延迟秒)；不可用返回 null。
  /// 能拿到 HTTP 响应即视为可用（zlibrary 根路径常返 503 但站点实际可用）。
  /// 对应 cmbook StartupCheckThread._probe_zlibrary_url。
  Future<_Probe?> _probeUrl(String url) async {
    if (url.isEmpty) return null;
    final target = url.startsWith('http://') || url.startsWith('https://')
        ? url
        : 'https://$url';
    final dio = Dio(
      BaseOptions(
        connectTimeout: const Duration(seconds: 15),
        receiveTimeout: const Duration(seconds: 15),
        followRedirects: true,
        validateStatus: (_) => true,
        headers: {
          'user-agent': _browserUa,
          'accept':
              'text/html,application/xhtml+xml,application/xml;q=0.9,image/avif,image/webp,*/*;q=0.8',
        },
      ),
    );
    // 连接异常重试 1 次（对抗跨境网络瞬时抖动，避免单次超时误判不可用）
    for (var attempt = 0; attempt < 2; attempt++) {
      try {
        final sw = Stopwatch()..start();
        final resp = await dio.get(target);
        final latency = sw.elapsedMilliseconds / 1000.0;
        // 取最终落地域名（跟随重定向后）
        String finalHost;
        if (resp.redirects.isNotEmpty) {
          final h = resp.redirects.last.location.host;
          finalHost = h.isNotEmpty ? h : url;
        } else {
          finalHost = Uri.tryParse(target)?.host ?? url;
        }
        return _Probe(finalHost, latency);
      } on DioException catch (e) {
        _log('探测 $url 第${attempt + 1}次失败: $e');
        if (attempt == 1) return null;
      } catch (e) {
        _log('探测 $url 失败: $e');
        return null;
      }
    }
    return null;
  }

  /// 定时健康检查（30 分钟）：先探当前域名，可用则保持；不可用才从候选重新选最优。
  /// 仅状态变化才 notify（_setUnavailable 内部守卫）。对应 cmbook _probe_candidates。
  Future<void> _healthCheck() async {
    // 夜间（23:00~次日 07:00 本地时间）不探测，避免无谓的后台联网唤醒
    final h = DateTime.now().hour;
    if (h < 7 || h >= 23) return;
    if (_candidates.isEmpty) return; // 无候选列表，沿用本地，不误报
    _log('定时健康检查: domain=$_domain, candidates=$_candidates');
    // 先探当前域名：可用则保持
    if (_domain.isNotEmpty) {
      final probe = await _probeUrl(_domain);
      if (probe != null) {
        _setUnavailable(false);
        return;
      }
    }
    // 当前不可用：从候选重新探测选最优
    final best = await _pickBestCandidate(_candidates);
    if (best != null) {
      if (best != _domain) {
        _domain = best;
        await _persistDomain();
      }
      _setUnavailable(false);
    } else {
      _setUnavailable(true);
    }
    notifyListeners();
  }
}

class _Probe {
  final String domain;
  final double latency;
  const _Probe(this.domain, this.latency);
}

class _Token {
  final String userid;
  final String userkey;
  const _Token(this.userid, this.userkey);
}
