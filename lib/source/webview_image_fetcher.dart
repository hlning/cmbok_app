// WebView 取图器（从 spike webview_fetch_test_page 提炼）。
//
// iframe/懒加载站点（useFrame=1）取图：WebView 加载章节页 -> 注入快取脚本扫
// DOM属性/<script>/performance 全部图片 URL -> 用 imgDom 已渲染 src 的路径前缀
// 过滤出章节图（spike 验证 MYCOMIC 30->20，不滚动秒取）。
//
// imgScript 模式（加密/JS 渲染站，如来漫画 picTree base64）：执行配置的取图 JS
// （注入 ifr={contentWindow:window} 适配 app 无 iframe），通用机制，新增加密站
// 只改配置不改代码。
//
// 全局单例：持 WebViewController，通过 buildHiddenWebView() 在根 Stack 挂 1px 隐藏
// WebViewWidget（底层，被 HomePage 覆盖不可见，但确保平台视图运行）。下载/阅读都走它。
// 串行化（Future 链）：一次只跑一个 fetch，避免并发 loadRequest 冲突。

import 'dart:async';
import 'dart:convert';
import 'dart:io' show Directory, File, Platform;
import 'dart:math' as math;
import 'dart:typed_data' show Uint8List;

import 'package:dio/dio.dart';
import 'package:encrypt/encrypt.dart' as enc;
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:webview_flutter/webview_flutter.dart';

import 'site_config.dart';
import 'image_restore.dart';

void _log(String message) {
  debugPrint('[WebViewImageFetcher] $message');
}

class WebViewImageFetcher {
  static final WebViewImageFetcher _instance = WebViewImageFetcher._();
  factory WebViewImageFetcher() => _instance;
  WebViewImageFetcher._();

  /// 浏览器式请求头（直下图片用，调用方可按需覆盖/追加 Referer）
  static final Map<String, String> _browserHeaders = {
    'User-Agent':
        'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
        '(KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36',
  };

  late final WebViewController controller;
  bool _initialized = false;

  /// 串行化：fetch 依次排队执行，_last 完成后才跑下一个
  Future<void> _last = Future.value();

  /// webview_flutter 仅提供 Android/iOS 平台实现；桌面端（Windows/macOS/Linux）
  /// 无对应 WebViewPlatform，构造 WebViewController 会触发断言。桌面端不初始化，
  /// 取图/抓页等 WebView 能力不可用（调用方 try/catch 会优雅降级）。
  bool get _supported => Platform.isAndroid || Platform.isIOS;

  void init() {
    if (_initialized) return;
    if (!_supported) {
      throw UnsupportedError('WebView 取图仅支持 Android/iOS，当前平台不可用');
    }
    controller = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setNavigationDelegate(
        NavigationDelegate(
          onPageFinished: (_) => _pageCompleter?.complete(),
          onWebResourceError: (e) {
            // 子资源错误（如 ORB 阻止的跨域图片、广告、favicon 等）很常见，
            // 不应中断主页面加载。只记日志，页面是否成功以 onPageFinished 为准，
            // 主页面真失败由 30s 超时兜底。
            _log('资源错误: ${e.description} (忽略，不影响主页面)');
          },
        ),
      );
    _initialized = true;
  }

  Completer<void>? _pageCompleter;

  /// 根树挂载的 1px 隐藏 WebView（放 Stack 最底层，被上层覆盖不可见）。
  /// 1px 可见尺寸确保 Android/iOS 平台视图正常创建与加载（Offstage/0 尺寸可能不运行）。
  Widget buildHiddenWebView() {
    // 桌面端无 WebView 平台实现，不挂载（返回零尺寸占位，作为 Stack 子项合法）
    if (!_supported) return const SizedBox.shrink();
    init();
    return Positioned(
      left: 0,
      top: 0,
      child: SizedBox(
        width: 1,
        height: 1,
        child: WebViewWidget(controller: controller),
      ),
    );
  }

  /// 取图：加载章节页 -> 快取脚本扫全部图片 URL -> imgDom 前缀过滤章节图。
  /// 串行执行（多个 fetch 排队）。
  Future<List<String>> fetch(String url, SiteConfig site) async {
    init();
    final f = _last.then((_) => _doFetch(url, site));
    // 把本次结果（含异常）接入 _last，保证后续 fetch 不被异常打断串行链
    _last = f.then((_) {}, onError: (_) {});
    return f;
  }

  /// 加载页面并返回渲染后的 HTML（documentElement.outerHTML）。
  /// 用于 Cloudflare 防护等 Dio 无法直连的站点：搜索/分类/详情/章节走此通道，
  /// ConfigMangaSource._fetchHtml 在 useWebViewFetch=true 时调用。复用单例 WebView
  /// + 串行队列（与取图串行，避免 loadRequest 冲突）。
  Future<String> fetchHtml(String url) async {
    init();
    final f = _last.then((_) => _doFetchHtml(url));
    _last = f.then((_) {}, onError: (_) {});
    return f;
  }

  /// 解析下载短链最终 URL（用于 z-library 分类下载 `/dl/{slug}`）。
  ///
  /// z-library `/dl/{slug}` 被 Cloudflare JS 挑战拦死（Dio 直连返回 503 挑战页），
  /// 且 z-library 短链跳转到 CDN（如 `dln1.ncdn.ec`）后，webview 内 XHR 读取
  /// responseURL 会被 CORS 拦死 —— 但浏览器**会**把"redirected from ... to ..."的
  /// CORS 错误信息打到 console.error，其中含完整最终 CDN URL。
  ///
  /// 策略：在 webview 内 loadRequest z-library 任意页（建立 cookie/域/CF 上下文），
  /// 然后注入 JS 用 fetch 同域请求 `/dl/{slug}`（fetch 跟随重定向，浏览器自动跑
  /// CF 挑战 + 302 链），最终读 CDN response 时被 CORS 拦抛错 —— 用
  /// `setOnConsoleMessage` 捕获 console.error 文本，正则提取 `redirected from ...
  /// '(...) ' ` 中的最终 URL。
  Future<String> resolveDownloadUrl(String url) async {
    init();
    final f = _last.then((_) => _doResolveDownloadUrl(url));
    _last = f.then((_) {}, onError: (_) {});
    return f;
  }

  Future<String> _doResolveDownloadUrl(String url) async {
    _log('解析下载短链: $url');
    final completer = Completer<String>();
    final zlHost = Uri.parse(url).host;
    final matchedHosts = <String>{zlHost};
    // 注入前先挂 console 监听：捕获含跨域 CDN URL 的 console 消息（CORS 错误含
    // 'redirected from' 字样，含完整 CDN URL）。
    var consoleCount = 0;
    await controller.setOnConsoleMessage((msg) {
      consoleCount++;
      final text = msg.message;
      if (completer.isCompleted) return;
      _log('console[${msg.level.name}]: $text');
      if (text.isEmpty) return;
      final matches = RegExp(r"'(https?://[^']+)'").allMatches(text);
      for (final m in matches) {
        final u = m.group(1) ?? '';
        if (u.isEmpty) continue;
        final h = Uri.tryParse(u)?.host;
        if (h != null && h.isNotEmpty && !matchedHosts.contains(h)) {
          _log('从 console 提取到 CDN URL: $u');
          completer.complete(u);
          return;
        }
      }
    });
    try {
      // 第一步：加载 z-library 任意页面建立 cookie/域上下文（带 CF JS 挑战通过）
      await _loadPage('https://$zlHost/');
      // 等 CF JS 挑战通过 + cookie 落地（~1.5s）
      await Future.delayed(const Duration(milliseconds: 1500));
      // 第二步：注入 XHR 同域请求 /dl/{slug}，浏览器自动跑 CF 挑战 + 跟随 302 到 CDN，
      // 跨域读 response 被 CORS 拦截，错误（含 redirected-from 信息）打到 console。
      await controller.runJavaScript('''
(function(){
  try {
    var xhr = new XMLHttpRequest();
    xhr.open('GET', ${jsonEncode(url)}, true);
    xhr.send();
  } catch(e) { console.error('XHR throw: ' + e); }
})();
''');
      final result = await completer.future.timeout(
        const Duration(seconds: 15),
        onTimeout: () => '',
      );
      _log('console 总消息数=$consoleCount');
      if (result.isEmpty) {
        throw Exception('未捕获到 CDN URL（console 总 $consoleCount 条）');
      }
      return result;
    } catch (e) {
      _log('解析下载地址失败: $e');
      rethrow;
    } finally {
      await controller.setOnConsoleMessage((_) {});
    }
  }

  /// 取章节列表（chapterScript 模式）：3 阶段 fetchHtml 直连。
  /// 阶段1：详情页 chapterScript 返回 {apiUrl, linkBase}（不 fetch，避开 CORS）。
  /// 阶段2：loadRequest(apiUrl) 直连 API（浏览器绕 TLS 指纹拦截）-> body.textContent 取 JSON。
  /// 阶段3：注入 json+linkBase -> chapterJsonScript 返回 [{name,url}]。
  /// 用于 SSR 无章节、API 跨域被 CORS 拦 in-page fetch 的站点（如 godamh）。
  /// 串行队列复用（与取图/抓页串行，避免 loadRequest 冲突）。
  Future<List<Map<String, String>>> fetchChapters(
    String url,
    String chapterScript,
    String chapterJsonScript,
  ) async {
    init();
    final f = _last.then(
      (_) => _doFetchChapters(url, chapterScript, chapterJsonScript),
    );
    _last = f.then((_) {}, onError: (_) {});
    return f;
  }

  Future<List<Map<String, String>>> _doFetchChapters(
    String url,
    String chapterScript,
    String chapterJsonScript,
  ) async {
    _log('取章节开始: $url');
    // 阶段1：详情页拿 apiUrl + linkBase
    await _loadPage(url);
    // 等 SPA 渲染稳定（chapterDrawerConfig data 属性 SSR 即有，给 JS 就绪余量）
    await Future.delayed(const Duration(milliseconds: 1000));
    final cfg = await _runAsyncScript(chapterScript);
    if (cfg is! Map) {
      _log('取章节失败: chapterScript 未返回 {apiUrl,linkBase}');
      return [];
    }
    final apiUrl = cfg['apiUrl']?.toString() ?? '';
    final linkBase = cfg['linkBase']?.toString() ?? '';
    if (apiUrl.isEmpty) {
      _log('取章节失败: apiUrl 为空');
      return [];
    }
    _log('取章节 apiUrl=$apiUrl linkBase=$linkBase');
    // 阶段2：直连 API 取 JSON（loadRequest 绕 CORS/TLS 拦截）
    await _loadPage(apiUrl);
    final rawJson = await controller.runJavaScriptReturningResult(
      'document.body ? (document.body.textContent || "") : ""',
    );
    var jsonStr = _unwrapJsString(rawJson).trim();
    // JSON 在 WebView 常被包在 <pre>，截首末大括号
    final start = jsonStr.indexOf('{');
    final end = jsonStr.lastIndexOf('}');
    if (start >= 0 && end > start) {
      jsonStr = jsonStr.substring(start, end + 1);
    }
    // 阶段3：解析 JSON 映射章节
    final result = <Map<String, String>>[];
    if (jsonStr.isNotEmpty) {
      final scriptBody =
          '''
var json = JSON.parse(${jsonEncode(jsonStr)});
var linkBase = ${jsonEncode(linkBase)};
$chapterJsonScript
''';
      final parsed = await _runAsyncScript(scriptBody);
      if (parsed is List) {
        for (final e in parsed) {
          if (e is Map) {
            final name = e['name']?.toString() ?? '';
            final u = e['url']?.toString() ?? '';
            if (u.isNotEmpty) result.add({'name': name, 'url': u});
          }
        }
      }
    }
    _log(
      '取章节 ${result.length} 个: ${result.take(2).map((c) => c["name"]).join(", ")}',
    );
    return result;
  }

  /// 加载页面并等待 onPageFinished（复用 _pageCompleter）。
  Future<void> _loadPage(String url) async {
    _pageCompleter = Completer<void>();
    await controller.loadRequest(Uri.parse(url));
    try {
      await _pageCompleter!.future.timeout(const Duration(seconds: 30));
    } catch (e) {
      _log('页面加载失败: $url -> $e');
      rethrow;
    }
  }

  /// 注入 async 脚本并轮询结果（scriptBody 作为 async 函数体，可 return/await）。
  /// 返回 decoded JSON（Map/List/标量）；脚本抛错则抛 Exception。
  /// [chunkSize] > 0 时分批回传：结果可能是整章 base64 图片（100MB+），
  /// 一次 JSON.stringify 跨 WebView JS 桥会在 Java 侧产生等大的单次分配，
  /// 直接 OOM 崩溃（摸摸漫画实测 121MB 分配 vs 256MB 堆上限）。
  /// 分批后单次桥传输只有几 MB。
  Future<dynamic> _runAsyncScript(
    String scriptBody, {
    int chunkSize = 0,
  }) async {
    final inject =
        '''
(function(){
  window._fetchDone = false;
  window._fetchResult = null;
  (async function(){
    try {
      var result = await (async function(){
$scriptBody
      })();
      window._fetchResult = (result === null || result === undefined) ? [] : result;
    } catch(e) {
      window._fetchResult = { "__error": e && e.message ? e.message : String(e) };
    }
    window._fetchDone = true;
  })();
})();
''';
    await controller.runJavaScript('window._fetchDone = false;');
    await controller.runJavaScript(inject);
    // API/渲染可能较慢，轮询 30s（500ms × 60）
    for (var i = 0; i < 60; i++) {
      await Future.delayed(const Duration(milliseconds: 500));
      final done = await controller.runJavaScriptReturningResult(
        'window._fetchDone === true ? 1 : 0',
      );
      if (done == 1) {
        // 先探结果形态：错误对象是小对象，直接回传；数组则按 chunkSize 分批
        final probeRaw = await controller.runJavaScriptReturningResult(
          'JSON.stringify({err: (window._fetchResult && window._fetchResult.__error)'
          ' ? String(window._fetchResult.__error) : "",'
          ' n: Array.isArray(window._fetchResult) ? window._fetchResult.length : 0})',
        );
        final probe = jsonDecode(_unwrapJsString(probeRaw));
        if (probe is Map && (probe['err'] as String? ?? '').isNotEmpty) {
          throw Exception('取章节脚本错误: ${probe['err']}');
        }
        final total = (probe is Map ? probe['n'] : 0) as int? ?? 0;
        if (chunkSize <= 0 || total == 0) {
          final raw = await controller.runJavaScriptReturningResult(
            'JSON.stringify(window._fetchResult)',
          );
          final jsonStr = _unwrapJsString(raw);
          final decoded = jsonDecode(jsonStr);
          if (decoded is Map && decoded.containsKey('__error')) {
            final errMsg = decoded['__error']?.toString() ?? 'unknown';
            throw Exception('取章节脚本错误: $errMsg');
          }
          return decoded;
        }
        // 分批回传：逐段 slice + JSON.stringify，单次桥负载 = chunkSize 张
        final merged = <dynamic>[];
        for (var i = 0; i < total; i += chunkSize) {
          final end = (i + chunkSize) < total ? i + chunkSize : total;
          final raw = await controller.runJavaScriptReturningResult(
            'JSON.stringify(window._fetchResult.slice($i, $end))',
          );
          final decoded = jsonDecode(_unwrapJsString(raw));
          if (decoded is List) {
            merged.addAll(decoded);
          }
        }
        return merged;
      }
    }
    throw Exception('取章节轮询超时');
  }

  Future<List<String>> _doFetch(String url, SiteConfig site) async {
    _log('取图开始: $url');
    _pageCompleter = Completer<void>();
    await controller.loadRequest(Uri.parse(url));
    try {
      await _pageCompleter!.future.timeout(const Duration(seconds: 30));
    } catch (e) {
      _log('页面加载失败: $e');
      rethrow;
    }
    // 等懒加载/JS 渲染稳定（spike 经验：加载完成后再等 ~800ms 拿全）
    await Future.delayed(const Duration(milliseconds: 800));

    // imgLoadMode=2（滚到底）：懒加载站需逐段滚动到底，触发剩余图片加载。
    if (site.imgLoadMode == 2 && site.imgDom.isNotEmpty) {
      await _scrollToLoadAll(site.imgDom);
    }

    // blob: 图片还原：有些站（如摸摸漫画）把图片 fetch 成 blob URL，DOM 里只有 blob:，
    // performance 里有真实请求 URL。用 fetch 响应的 responseURL 或按内容大小匹配，
    // 把真实 URL 写回 data-original，后续通用快取就能识别。
    await _restoreBlobImages();

    // TODO(2b): imgLoadMode=3（下一页）站一页一图，需循环 next_page 翻页合并。
    //   2a 验证站（MYCOMIC/咚漫）均为 mode 2，快取可一次拿全；mode 3 暂返回当前页。
    if (site.imgLoadMode == 3) {
      _log('imgLoadMode=3（下一页）暂未实现翻页，仅取当前页');
    }

    return _extract(site);
  }

  /// 渐进式滚动加载：imgLoadMode=2 的站（如摸摸漫画章节页）滚动时追加新的
  /// div/img 元素到 DOM（非懒加载，是无限滚动/分页追加）。每次滚到底部触发下一批，
  /// 监控 img 数量，连续 3 轮无增长则认为已追加完毕。
  /// 最大滚动 80 轮，避免无限滚动页卡死。
  Future<void> _scrollToLoadAll(String imgDom) async {
    final imgDomJson = jsonEncode(imgDom);
    var lastCount = await _queryImgCount(imgDomJson);
    var stableRounds = 0;
    for (var i = 0; i < 80; i++) {
      // 直接滚到接近底部，触发站点追加下一批 div/img
      await controller.runJavaScript(
        'window.scrollTo(0, document.body.scrollHeight);',
      );
      // 等站点追加元素 + 图片 fetch 转 blob
      await Future.delayed(const Duration(milliseconds: 1200));
      final count = await _queryImgCount(imgDomJson);
      if (count == lastCount) {
        stableRounds++;
        // 连续 3 轮无增长，认为已追加完毕
        if (stableRounds >= 3) break;
      } else {
        stableRounds = 0;
        lastCount = count;
      }
    }
    _log('滚动加载完成: imgDom 内图片 $lastCount 张');
  }

  /// 查询 imgDom 内当前图片数量。
  Future<int> _queryImgCount(String imgDomJson) async {
    try {
      final raw = await controller.runJavaScriptReturningResult(
        '(document.querySelectorAll($imgDomJson)||[]).length',
      );
      if (raw is int) return raw;
      return int.tryParse(raw.toString()) ?? 0;
    } catch (e) {
      return 0;
    }
  }

  /// blob: 图片还原：摸摸漫画等站把图片 fetch 为 blob URL，DOM 中只有 blob: 前缀地址。
  /// 双策略：
  ///   1) 按 alt 匹配：img.alt 非空时，在 performance 图片资源 URL 中查找含 alt 文本的
  ///      资源（列表页封面 id 通常在 URL 路径里，命中率高）。
  ///   2) 顺序对齐：未匹配上的剩余 blob img，按 DOM 顺序与 performance 中最后 N 张
  ///      图片资源一一对应（章节图加载顺序与 DOM 顺序一致，命中率高）。
  Future<void> _restoreBlobImages() async {
    try {
      final raw = await controller.runJavaScriptReturningResult(r'''
(function(){
  try {
    var perfImgs = [];
    if (window.performance && performance.getEntriesByType) {
      var entries = performance.getEntriesByType('resource');
      for (var i = 0; i < entries.length; i++) {
        var name = entries[i].name;
        if (/\.(jpe?g|png|webp|gif|bmp)(\?|#|$)/i.test(name) && name.indexOf('blob:') !== 0) {
          perfImgs.push(name);
        }
      }
    }
    var blobImgs = document.querySelectorAll('img[src^="blob:"]');
    var matchedAlt = 0;
    var matchedOrder = 0;
    var unmatched = [];

    // 策略 1: 按 alt/父链接 href 匹配（列表页封面 id 在 URL 中）
    // alt 是漫画 id（如 "53329"），封面图通常在 <a href="/comics/53329"> 内，
    // 优先 alt，再用最近父级 a 的 href 作为匹配键。
    for (var i = 0; i < blobImgs.length; i++) {
      var img = blobImgs[i];
      if (img.getAttribute('data-src') || img.getAttribute('data-original') ||
          img.getAttribute('data-lazy-src') || img.getAttribute('data-url')) {
        continue;
      }
      var keys = [];
      var alt = (img.getAttribute('alt') || '').trim();
      if (alt) keys.push(alt);
      var parent = img.closest('a[href]');
      if (parent) {
        var href = parent.getAttribute('href') || '';
        var m = href.match(/\/(\d+)(?:[\/?#]|$)/);
        if (m && keys.indexOf(m[1]) === -1) keys.push(m[1]);
      }
      var found = false;
      for (var k = 0; k < keys.length && !found; k++) {
        for (var j = 0; j < perfImgs.length; j++) {
          if (perfImgs[j].indexOf(keys[k]) !== -1) {
            img.setAttribute('data-original', perfImgs[j]);
            matchedAlt++;
            found = true;
            break;
          }
        }
      }
      if (!found) {
        unmatched.push(img);
      }
    }

    // 策略 2: 顺序对齐（章节图等无 alt 的场景）
    if (unmatched.length > 0 && perfImgs.length >= unmatched.length) {
      var startIdx = perfImgs.length - unmatched.length;
      for (var i = 0; i < unmatched.length; i++) {
        var img = unmatched[i];
        var realUrl = perfImgs[startIdx + i];
        if (realUrl) {
          img.setAttribute('data-original', realUrl);
          matchedOrder++;
        }
      }
    }
    return JSON.stringify({
      blobCount: blobImgs.length,
      perfImgCount: perfImgs.length,
      matchedAlt: matchedAlt,
      matchedOrder: matchedOrder,
      unmatched: unmatched.length - matchedOrder
    });
  } catch(e) {
    return JSON.stringify({error: String(e)});
  }
})();
''');
      _log('blob 图片还原: ${_unwrapJsString(raw)}');
    } catch (e) {
      _log('blob 图片还原失败（忽略）: $e');
    }
  }

  Future<String> _doFetchHtml(String url) async {
    _log('抓取页面: $url');
    _pageCompleter = Completer<void>();
    await controller.loadRequest(Uri.parse(url));
    try {
      await _pageCompleter!.future.timeout(const Duration(seconds: 30));
    } catch (e) {
      _log('页面加载失败: $e');
      rethrow;
    }
    // 等 SPA/Alpine 渲染稳定（列表页内容较多，给足时间）
    await Future.delayed(const Duration(milliseconds: 1000));
    // blob 图片还原（摸摸漫画等站封面图是 blob URL）
    await _restoreBlobImages();
    // outerHTML 经 JSON.stringify -> _unwrapJsString -> jsonDecode 还原
    // （正确处理换行/引号/反斜杠转义，避免 _unwrapJsString 漏转 \n 等）
    final raw = await controller.runJavaScriptReturningResult(
      'JSON.stringify(document.documentElement.outerHTML)',
    );
    return jsonDecode(_unwrapJsString(raw)) as String;
  }

  Future<List<String>> _extract(SiteConfig site) async {
    // imgScript 优先（配置驱动，适用加密/JS 渲染站，支持 await 调站点 API）；
    // 失败或返回空则重试（等 JS 就绪），仍失败回退通用快取。
    var imgs = <String>[];
    if (site.imgScript.isNotEmpty) {
      for (var attempt = 1; attempt <= 3; attempt++) {
        try {
          final r = await _runScript(_imgScriptBody(site.imgScript));
          if (r.isNotEmpty) {
            imgs = r;
            _log(
              'imgScript 取到 ${imgs.length} 张（尝试 $attempt）: ${_safeImgPreview(imgs.first)}',
            );
            break;
          }
          _log('imgScript 尝试 $attempt 返回空');
          if (attempt == 1) await _diagnose();
        } catch (e) {
          _log('imgScript 尝试 $attempt 失败: $e');
          if (attempt == 1) await _diagnose();
        }
        if (attempt < 3) {
          await Future.delayed(const Duration(milliseconds: 500));
        }
      }
      if (imgs.isEmpty) _log('imgScript 3 次均失败/空，回退通用快取');
    }
    if (imgs.isEmpty) {
      imgs = await _runScript(_scanScriptBody(site));
      _log(
        '通用快取取到 ${imgs.length} 张${imgs.isNotEmpty ? ": ${_safeImgPreview(imgs.first)}" : ""}',
      );
    }
    // AES 加密站（如漫蛙，img_aes_key 非空）：WebView 只负责拿真实 URL 列表，
    // 密文由 Dio 并发直下、本地 AES-CBC 解密落盘——比 WebView 内逐张
    // fetch+解密+blob+base64 桥接快得多
    if (site.imgAesKey.isNotEmpty && imgs.isNotEmpty) {
      _log('AES 加密站，Dio 直下 + 本地解密');
      final fileImgs = await _downloadAndDecryptImages(imgs, site);
      if (fileImgs.isNotEmpty) {
        _log('解密落盘取到 ${fileImgs.length} 张');
        return fileImgs;
      }
      _log('解密落盘失败，回退 WebView 取图');
    }
    // useBlobBase64 站（如摸摸漫画）：图片被 fetch 为 blob URL，通用快取拿到
    // 的真实 URL 外部请求因防盗链失败，需在 WebView 内转 base64 再逐张落盘临时文件。
    // 非 useBlobBase64 的 blob 站：_restoreBlobImages 已把真实 URL 写回 data-original，
    // 通用快取拿到的 URL 可直连，不走 base64。
    if (site.useBlobBase64 && imgs.isNotEmpty && site.imgDom.isNotEmpty) {
      _log('useBlobBase64 站，逐张落盘取图');
      final fileImgs = await _fetchImagesToTempFiles(site.imgDom);
      if (fileImgs.isNotEmpty) {
        _log('落盘取到 ${fileImgs.length} 张');
        return fileImgs;
      }
    }
    return imgs;
  }

  /// 章节图字节还原（共享 image_restore 工具的薄封装）
  List<int> _restoreImageBytes(List<int> bytes, enc.Key? aesKey) =>
      restoreImageBytes(bytes, aesKey?.bytes);

  bool _isImageMagic(List<int> b) => isImageMagic(b);

  /// URL 规律直下（imgUrlPattern 非空，如摸摸 c2.2thewash.com）：完全跳过
  /// WebView——章节 URL 经 imgUrlIdRegex 提取 comicId/chapterNo 填入模板，
  /// index 从 1 递增 8 并发 GET，404 即章节结尾。响应体按 imgBodyBase64
  /// （base64 文本）/imgAesKey（AES 密文）还原后落盘临时文件。
  /// 第 1 张即失败返回 []，由上层回退 WebView 路径。
  Future<List<String>> fetchByPattern(
    String chapterUrl,
    SiteConfig site,
  ) async {
    if (site.imgUrlPattern.isEmpty) return [];
    final sw = Stopwatch()..start();
    final m = RegExp(site.imgUrlIdRegex).firstMatch(chapterUrl);
    if (m == null || m.groupCount < 2) {
      _log('URL 规律直下: URL 不匹配正则 ${site.imgUrlIdRegex}');
      return [];
    }
    final comicId = m.group(1)!;
    final chapterNo = m.group(2)!;
    String urlOf(int i) => site.imgUrlPattern
        .replaceAll('{comicId}', comicId)
        .replaceAll('{chapterNo}', chapterNo)
        .replaceAll('{index}', '$i');

    final dio = Dio(
      BaseOptions(
        responseType: site.imgBodyBase64
            ? ResponseType.plain
            : ResponseType.bytes,
        connectTimeout: const Duration(seconds: 15),
        receiveTimeout: const Duration(seconds: 30),
        // 404 = 章节结尾，正常返回不抛异常
        validateStatus: (s) => s != null && s < 500,
        headers: {..._browserHeaders, 'Referer': site.url},
      ),
    );
    enc.Key? aesKey;
    if (site.imgAesKey.isNotEmpty) {
      final kb = utf8.encode(site.imgAesKey);
      if (kb.length >= 32) {
        aesKey = enc.Key(Uint8List.fromList(kb.sublist(0, 32)));
      }
    }

    List<int> restore(Object? data) {
      if (site.imgBodyBase64) {
        final text = (data as String?) ?? '';
        return _restoreImageBytes(
          base64.decode(text.replaceAll(RegExp(r'\s'), '')),
          aesKey,
        );
      }
      return _restoreImageBytes((data as List<int>?) ?? const [], aesKey);
    }

    try {
      // 探第 1 张验证 URL 规律
      final first = await dio.get<Object>(urlOf(1));
      if (first.statusCode != 200) {
        _log('URL 规律直下: 第 1 张 ${first.statusCode}，回退');
        return [];
      }
      final tempDir = await _newBlobTempDir();
      final byIndex = <int, String>{};
      Future<void> save(int i, Object? data) async {
        final out = restore(data);
        final file = File('$tempDir/${i.toString().padLeft(4, '0')}.jpg');
        await file.writeAsBytes(out, flush: true);
        byIndex[i] = file.path;
      }

      await save(1, first.data);
      // 8 并发推进到 404 为止
      var next = 2;
      var end = -1;
      var failed = 0;
      Future<void> worker() async {
        while (true) {
          final i = next++;
          if (end > 0 && i > end) break;
          try {
            final resp = await dio.get<Object>(urlOf(i));
            if (resp.statusCode == 404) {
              if (end < 0 || i < end) end = i;
              continue;
            }
            await save(i, resp.data);
          } catch (e) {
            failed++;
            _log('URL 规律直下第 $i 张失败: $e');
          }
        }
      }

      await Future.wait(List.generate(8, (_) => worker()));
      final paths = (byIndex.keys.toList()..sort())
          .map((k) => byIndex[k]!)
          .toList();
      _log(
        'URL 规律直下: ${paths.length} 张，失败 $failed，'
        '耗时 ${sw.elapsedMilliseconds / 1000}s',
      );
      return paths;
    } catch (e) {
      _log('URL 规律直下异常: $e');
      return [];
    }
  }

  /// AES 加密站（imgAesKey 非空，如漫蛙）：Dio 并发直下密文，
  /// 本地 AES-CBC 解密（密文 = 前 16 字节 IV + 密文，密钥取 utf-8 前 32 字节），
  /// 落盘临时文件返回路径。已是明文图片（魔数命中）的直接落盘。
  /// 6 并发；失败张跳过并在日志汇总。
  Future<List<String>> _downloadAndDecryptImages(
    List<String> urls,
    SiteConfig site,
  ) async {
    try {
      // Referer 用章节页地址（防盗链 CDN 通常要求）
      String pageUrl = site.url;
      try {
        final raw = await controller.runJavaScriptReturningResult(
          'location.href',
        );
        final u = _unwrapJsString(raw);
        if (u.startsWith('http')) pageUrl = u;
      } catch (_) {}
      final dio = Dio(
        BaseOptions(
          responseType: ResponseType.bytes,
          connectTimeout: const Duration(seconds: 15),
          receiveTimeout: const Duration(seconds: 30),
          headers: {
            'User-Agent':
                'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
                '(KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36',
            'Referer': pageUrl,
          },
        ),
      );
      final keyBytes = utf8.encode(site.imgAesKey);
      if (keyBytes.length < 32) {
        _log('imgAesKey 长度不足 32 字节，放弃本地解密');
        return [];
      }
      final key = enc.Key(Uint8List.fromList(keyBytes.sublist(0, 32)));

      final tempDir = await _newBlobTempDir();
      final paths = List<String?>.filled(urls.length, null);
      var next = 0;
      var plain = 0, decrypted = 0, failed = 0, done = 0;
      final sw = Stopwatch()..start();
      Future<void> worker() async {
        while (true) {
          final i = next++;
          if (i >= urls.length) break;
          try {
            final resp = await dio.get<List<int>>(urls[i]);
            final bytes = resp.data ?? const <int>[];
            if (bytes.isEmpty) throw Exception('空响应');
            final wasPlain = _isImageMagic(bytes);
            final out = _restoreImageBytes(bytes, key);
            if (wasPlain) {
              plain++;
            } else {
              decrypted++;
            }
            final file = File('$tempDir/${i.toString().padLeft(4, '0')}.jpg');
            await file.writeAsBytes(out, flush: true);
            paths[i] = file.path;
          } catch (e) {
            failed++;
            _log('直下解密失败 ${_safeImgPreview(urls[i])}: $e');
          }
          done++;
          if (done % 10 == 0) {
            _log(
              '直下解密进度 $done/${urls.length}，${sw.elapsedMilliseconds / 1000}s',
            );
          }
        }
      }

      final workers = List.generate(math.min(8, urls.length), (_) => worker());
      await Future.wait(workers);
      _log(
        '直下解密统计: 明文 $plain, 解密 $decrypted, 失败 $failed / 共 ${urls.length}，'
        '耗时 ${sw.elapsedMilliseconds / 1000}s',
      );
      return paths.whereType<String>().toList();
    } catch (e) {
      _log('直下解密异常: $e');
      return [];
    }
  }

  /// 逐张落盘临时文件：JS 侧一次异步取完全章 base64（存 window._fetchResult，
  /// WebView 进程内存不影响 App 堆），Dart 侧逐张桥取 → 解码 → 写临时文件 →
  /// 返回 file:// 路径。峰值 App 堆仅单张图片（几 MB），
  /// 而非整章 data: URL（100MB+）。
  Future<List<String>> _fetchImagesToTempFiles(String imgDom) async {
    try {
      // 1. JS 侧：一次异步取完全章 base64（存 window._fetchResult）
      final jsBody =
          '''
var imgDom = ${jsonEncode(imgDom)};
var imgs = document.querySelectorAll(imgDom);
var stats = { total: imgs.length, viaBaseUtil: 0, invalid: 0, canvas: 0, empty: 0 };
window._fetchProgress = { done: 0, total: imgs.length };
var isImageMagic = function(v) {
  return (v[0] === 0xFF && v[1] === 0xD8) || // JPEG
      (v[0] === 0x89 && v[1] === 0x50) || // PNG
      (v[0] === 0x47 && v[1] === 0x49) || // GIF
      (v[0] === 0x42 && v[1] === 0x4D) || // BMP
      (v[0] === 0x52 && v[1] === 0x49 && v[2] === 0x46 && v[3] === 0x46); // RIFF(WebP)
};
// 单张 20s 超时，避免个别请求挂起拖死全章
var fetchWithTimeout = async function(url) {
  var ctrl = new AbortController();
  var t = setTimeout(function() { ctrl.abort(); }, 20000);
  try {
    // 不带 credentials：跨域 CDN 常回 ACAO:*，credentials include 会被 CORS 拒绝
    return await fetch(url, { signal: ctrl.signal });
  } finally { clearTimeout(t); }
};
var processImg = async function(img) {
  // 站点初始 src 常是 1px 占位 gif，真实 URL 在 data-src（如漫蛙 .lazy-image）。
  // 已解密替换成 blob: 的 src 优先直用；否则取 data-src/data-original
  var s = img.src || '';
  var src = (s.indexOf('blob:') === 0) ? s :
      (img.getAttribute('data-src') || img.getAttribute('data-original') || s);
  if (!src || src.indexOf('data:') === 0) {
    return (src && src.indexOf('data:') === 0) ? src : '';
  }
  try {
    // 真实 URL（站点解密未触发/未完成，如漫蛙 IntersectionObserver 懒解密）：
    // 用站点自己的解密函数兜底（BaseUtil.getSecureImageUrl，AES-CBC 解密转 blob）。
    // 注意 BaseUtil 在 base.js 里是 const 声明，不挂 window，必须用裸标识符探测
    if (src.indexOf('blob:') !== 0 && typeof BaseUtil !== 'undefined' &&
        typeof BaseUtil.getSecureImageUrl === 'function') {
      // 解密内部 fetch 无超时，外层 race 25s 兜底防挂起
      var decrypted = await Promise.race([
        BaseUtil.getSecureImageUrl(src),
        new Promise(function(_, rej) {
          setTimeout(function() { rej(new Error('decrypt timeout')); }, 25000);
        }),
      ]);
      if (decrypted && decrypted !== src) { src = decrypted; stats.viaBaseUtil++; }
    }
    var resp = await fetchWithTimeout(src);
    if (!resp.ok) throw new Error('fetch failed: ' + resp.status);
    var buf = await resp.arrayBuffer();
    var v = new Uint8Array(buf);
    // 魔数校验：密文/错误页直接判失败走 canvas 兜底，不产出坏文件
    if (!isImageMagic(v)) {
      stats.invalid++;
      throw new Error('not an image: magic=' + v[0] + ',' + v[1]);
    }
    var bin = '';
    var CH = 32768;
    for (var o = 0; o < v.length; o += CH) {
      bin += String.fromCharCode.apply(null, v.subarray(o, Math.min(o + CH, v.length)));
    }
    return 'data:application/octet-stream;base64,' + btoa(bin);
  } catch(e) {
    // canvas 兜底：仅当站点已渲染出真实图（naturalWidth>10），
    // 占位 gif 画出来只是 1px 空图，不如留空让上层标记缺图
    if ((img.naturalWidth || 0) > 10) {
      try {
        var canvas = document.createElement('canvas');
        canvas.width = img.naturalWidth;
        canvas.height = img.naturalHeight;
        var ctx = canvas.getContext('2d');
        ctx.drawImage(img, 0, 0);
        var d = canvas.toDataURL('image/jpeg', 0.9);
        stats.canvas++;
        return d;
      } catch(e2) {}
    }
    stats.empty++;
    return '';
  }
};
// 6 并发取全章（串行逐张解密下载太慢，长章节会超轮询时限）
var results = new Array(imgs.length);
var next = 0;
var workers = [];
for (var w = 0; w < 6 && w < imgs.length; w++) {
  workers.push((async function() {
    while (true) {
      var i = next++;
      if (i >= imgs.length) break;
      results[i] = await processImg(imgs[i]);
      window._fetchProgress.done++;
    }
  })());
}
await Promise.all(workers);
window._fetchStats = stats;
return results;
''';
      await _injectAndAwaitScript(jsBody);

      // 2. 探结果形态（错误对象 vs 数组）+ 取图统计
      final probeRaw = await controller.runJavaScriptReturningResult(
        'JSON.stringify({err: (window._fetchResult && window._fetchResult.__error)'
        ' ? String(window._fetchResult.__error) : "",'
        ' n: Array.isArray(window._fetchResult) ? window._fetchResult.length : 0,'
        ' stats: window._fetchStats || {}})',
      );
      final probe = jsonDecode(_unwrapJsString(probeRaw));
      if (probe is Map && (probe['err'] as String? ?? '').isNotEmpty) {
        throw Exception('取章节脚本错误: ${probe['err']}');
      }
      final total = (probe is Map ? probe['n'] : 0) as int? ?? 0;
      if (probe is Map && probe['stats'] is Map) {
        _log('落盘取图统计: ${probe['stats']}');
      }
      if (total == 0) {
        _log('落盘取图: 无图片');
        return [];
      }

      // 3. 逐张桥取 → base64 解码 → 写临时文件 → 释放
      final tempDir = await _newBlobTempDir();
      final filePaths = <String>[];
      for (var i = 0; i < total; i++) {
        final raw = await controller.runJavaScriptReturningResult(
          'JSON.stringify(window._fetchResult[$i])',
        );
        final dataUrl = jsonDecode(_unwrapJsString(raw)) as String? ?? '';
        if (dataUrl.isEmpty) continue;
        final commaIdx = dataUrl.indexOf(',');
        if (commaIdx < 0) continue;
        final bytes = base64.decode(dataUrl.substring(commaIdx + 1));
        final file = File('$tempDir/${i.toString().padLeft(4, '0')}.jpg');
        await file.writeAsBytes(bytes, flush: true);
        filePaths.add(file.path);
        // bytes + dataUrl 可 GC
      }
      _log('落盘取图: $total 张 → ${filePaths.length} 文件');
      return filePaths;
    } catch (e) {
      _log('落盘取图失败: $e');
      return [];
    }
  }

  /// 注入异步脚本并轮询直到完成（结果留在 window._fetchResult，
  /// 调用方自行取回）。供 _fetchImagesToTempFiles 使用。
  Future<void> _injectAndAwaitScript(String scriptBody) async {
    final inject =
        '''
(function(){
  window._fetchDone = false;
  window._fetchResult = null;
  (async function(){
    try {
      var result = await (async function(){
$scriptBody
      })();
      window._fetchResult = (result === null || result === undefined) ? [] : result;
    } catch(e) {
      window._fetchResult = { "__error": e && e.message ? e.message : String(e) };
    }
    window._fetchDone = true;
  })();
})();
''';
    await controller.runJavaScript('window._fetchDone = false;');
    await controller.runJavaScript(inject);
    // 600×500ms=5min：加密站逐张解密下载全章（60+ 张走代理）耗时长，
    // 每 10s 记一次进度，避免静默超时难排查
    var lastLogged = -1;
    for (var i = 0; i < 600; i++) {
      await Future.delayed(const Duration(milliseconds: 500));
      final done = await controller.runJavaScriptReturningResult(
        'window._fetchDone === true ? 1 : 0',
      );
      if (done == 1) return;
      if (i % 20 == 19) {
        try {
          final p = await controller.runJavaScriptReturningResult(
            'JSON.stringify(window._fetchProgress || {})',
          );
          final prog = jsonDecode(_unwrapJsString(p));
          final d = (prog is Map ? prog['done'] : 0) as int? ?? 0;
          final t = (prog is Map ? prog['total'] : 0) as int? ?? 0;
          if (d != lastLogged) {
            lastLogged = d;
            _log('取章节进行中: $d/$t');
          }
        } catch (_) {}
      }
    }
    throw Exception('取章节轮询超时');
  }

  /// 临时文件根目录（应用缓存目录/cmbok_blob_temp/）
  Future<String> get _blobTempRoot async =>
      '${(await getTemporaryDirectory()).path}/cmbok_blob_temp';

  var _blobSeq = 0;

  /// 每次章节取图新建独立子目录（序号递增）。
  /// 路径随取图变化，避免切章节时 ImageCache 按相同文件路径命中上一话旧图；
  /// 同时清掉旧子目录（保留最近 2 个，可能仍被阅读器展示），控制临时空间。
  Future<String> _newBlobTempDir() async {
    // 先同步取号：await 之后再自增，两次并发调用可能拿到同一序号撞目录
    final seq = _blobSeq++;
    final root = Directory(await _blobTempRoot);
    if (!await root.exists()) await root.create(recursive: true);
    try {
      final subs = <int>[];
      await for (final e in root.list()) {
        if (e is Directory) {
          final n = int.tryParse(e.path.split(Platform.pathSeparator).last);
          if (n != null) subs.add(n);
        }
      }
      subs.sort();
      final keep = {seq - 1, seq};
      for (final s in subs) {
        if (!keep.contains(s)) {
          try {
            await Directory(
              '${root.path}${Platform.pathSeparator}$s',
            ).delete(recursive: true);
          } catch (_) {}
        }
      }
    } catch (_) {}
    final dir = Directory('${root.path}${Platform.pathSeparator}$seq');
    await dir.create(recursive: true);
    return dir.path;
  }

  /// 清理 blob 临时文件（阅读器退出/切章节时调用）
  Future<void> clearBlobTempFiles() async {
    try {
      final dir = Directory(await _blobTempRoot);
      if (await dir.exists()) await dir.delete(recursive: true);
    } catch (e) {
      _log('清理 blob 临时文件失败: $e');
    }
  }

  /// imgScript 失败/空时诊断：log 当前页面 URL/标题 + 取图函数就绪状态 +
  /// baozimh 相关 DOM（JSON script 数、comic-contain__item 数、amp-img 数、首张 data-src、
  /// 首个 JSON 内容），辅助排查 imgScript 为何取空。仅用于 log，不影响取图逻辑。
  Future<void> _diagnose() async {
    try {
      final raw = await controller.runJavaScriptReturningResult(r'''
JSON.stringify({url:location.href,title:document.title,getUrlpics:typeof getUrlpics,gethost:typeof gethost,picTree:typeof picTree,jsonScripts:document.querySelectorAll("script[type=\"application/json\"]").length,comicItems:document.querySelectorAll(".comic-contain__item").length,ampImgs:document.querySelectorAll("amp-img").length,firstItem:(function(){var e=document.querySelector(".comic-contain__item");return e?(e.getAttribute("data-src")||e.getAttribute("src")||"").slice(0,120):"";})(),firstJson:(function(){var s=document.querySelector("script[type=\"application/json\"]");return s?(s.textContent||"").slice(0,120):"";})()})
''');
      _log('诊断: ${_unwrapJsString(raw)}');
    } catch (e) {
      _log('诊断失败: $e');
    }
  }

  /// 执行取图脚本并轮询拿结果（imgScript 与通用快取共用）。
  Future<List<String>> _runScript(String scriptBody) async {
    // async 包装：脚本体内可用 await（如漫蛙 imgScript 调站点 API），
    // 同步脚本（通用快取等）await 同步值不受影响
    final inject =
        '''
(function(){
  window._fetchDone = false;
  Promise.resolve().then(async function(){
    try {
      var result = await ($scriptBody);
      window._fetchResult = (result === null || result === undefined) ? [] : result;
    } catch(e) {
      window._fetchResult = { "__error": e && e.message ? e.message : String(e) };
    }
    window._fetchDone = true;
  });
})();
''';
    await controller.runJavaScript('window._fetchDone = false;');
    await controller.runJavaScript(inject);
    for (var i = 0; i < 40; i++) {
      await Future.delayed(const Duration(milliseconds: 200));
      final done = await controller.runJavaScriptReturningResult(
        'window._fetchDone === true ? 1 : 0',
      );
      if (done == 1) {
        final raw = await controller.runJavaScriptReturningResult(
          'JSON.stringify(window._fetchResult)',
        );
        final jsonStr = _unwrapJsString(raw);
        final decoded = jsonDecode(jsonStr);
        if (decoded is Map && decoded.containsKey('__error')) {
          throw Exception('取图脚本错误: ${decoded['__error']}');
        }
        if (decoded is List) {
          return decoded.map((e) => e.toString()).toList();
        }
        return [];
      }
    }
    throw Exception('取图轮询超时');
  }

  /// imgScript 取图脚本：注入 ifr={contentWindow:window} 适配 app 无 iframe
  /// （桌面端 imgScript 的 ifr.contentWindow -> 章节页 window）；结果经 encodeURI
  /// （path 的 Unicode char 按 UTF-8 编码为 %XX，与浏览器一致）。
  /// 通用：任何配 img_script 的站都走此路径，新增加密站只改配置不改代码。
  String _imgScriptBody(String imgScript) {
    return '(async function(){'
        'var raw = await (async function(ifr){ $imgScript })({contentWindow: window});'
        'return (raw || []).map(function(u){ return encodeURI(u); });'
        '})()';
  }

  /// 通用快取脚本：扫 DOM属性 + <script> text + performance 资源，全部图片 URL；
  /// 用 imgDom 已渲染 src 的 pathname 目录作前缀过滤出章节图（剔除缩略图/logo/推荐）。
  String _scanScriptBody(SiteConfig site) {
    final imgDomJson = jsonEncode(site.imgDom);
    final imgAttrJson = jsonEncode(site.imgAttr);
    return r'''
(function(){
  var re = /https?:\/\/[^\s"'<>)\\]+\.(?:jpe?g|png|webp|gif)(?:[?#][^\s"'<>)]*)?/gi;
  // 按 pathname 去重：同一张图的 s1.bzcdn.net(SSR) 与 s1-ogsm1-uspho.bzcdn.net(区域节点)
  // 路径相同，保留先见（DOM 属性优先于 performance 资源，故保留可达的 SSR 主机）。
  var byPath = {}, order = [];
  function add(u){
    if(!u) return;
    re.lastIndex = 0;
    var m;
    while((m = re.exec(u)) !== null){
      var url = m[0];           // 仅取匹配到的 URL，丢弃 tap:AMP.setState(...) 等外壳
      try {
        var key = new URL(url, location.href).pathname;
        if(!(key in byPath)){ byPath[key] = url; order.push(url); }
      } catch(e){
        if(!(url in byPath)){ byPath[url] = url; order.push(url); }
      }
    }
  }
  document.querySelectorAll('*').forEach(function(el){
    for (var i=0;i<el.attributes.length;i++) add(el.attributes[i].value);
  });
  document.querySelectorAll('script').forEach(function(s){ add(s.textContent||''); });
  if (window.performance && performance.getEntriesByType)
    performance.getEntriesByType('resource').forEach(function(e){ add(e.name); });
  var allUrls = order;
  var imgDom = ''' +
        imgDomJson +
        r''';
  var imgAttr = ''' +
        imgAttrJson +
        r''';
  var prefix = null;
  if (imgDom) {
    var imgs = document.querySelectorAll(imgDom);
    for (var i=0;i<imgs.length;i++){
      var img = imgs[i];
      // 优先用配置的 imgAttr 取值；如果是 blob:（摸摸漫画等站），回退到 data-original
      // 等真实 URL 属性取路径前缀，否则前缀是 blob UUID 会过滤掉所有图。
      var a = imgAttr ? (img.getAttribute(imgAttr) || '') : (img.src || '');
      if (!a || a.indexOf('blob:') === 0 || a.indexOf('data:') === 0) {
        a = img.getAttribute('data-original') ||
            img.getAttribute('data-src') ||
            img.getAttribute('data-lazy-src') ||
            img.getAttribute('data-url') || '';
      }
      if (a && a.indexOf('data:')!==0 && a.indexOf('blob:')!==0) {
        try {
          var u = new URL(a, location.href);
          var p = u.pathname;
          var idx = p.lastIndexOf('/');
          if (idx > 0) { prefix = p.substring(0, idx+1); break; }
        } catch(e){}
      }
    }
  }
  var result;
  if (prefix) {
    result = allUrls.filter(function(u){
      try { return new URL(u, location.href).pathname.indexOf(prefix) === 0; }
      catch(e){ return false; }
    });
  } else {
    result = allUrls; // 无前缀（imgDom 无已渲染图），返回全部，由上层兜底
  }
  // 剔除站点图标/favicon 等非正文图（兜底全量时会把 <head> 的 apple-icon 当正文图加载致 403）
  result = result.filter(function(u){
    return !/(apple-touch-icon|apple-icon|favicon)/i.test(u);
  });
  return result;
})()
''';
  }

  /// 日志用：图片 URL 预览，data: base64 只打类型+长度，避免刷屏。
  String _safeImgPreview(String url) {
    if (url.startsWith('data:')) {
      final commaIdx = url.indexOf(',');
      final prefix = commaIdx > 0 ? url.substring(0, commaIdx) : 'data:';
      // base64 部分长度估算（去掉 data:xxx;base64, 前缀）
      final b64Len = url.length - commaIdx - 1;
      final bytesLen = (b64Len * 3 / 4).round();
      return '$prefix (~${_formatSize(bytesLen)})';
    }
    return url.length > 120 ? '${url.substring(0, 120)}...' : url;
  }

  String _formatSize(int bytes) {
    if (bytes < 1024) return '${bytes}B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)}KB';
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)}MB';
  }

  /// webview_flutter runJavaScriptReturningResult 对 JS 字符串值返回带引号字面量，
  /// 去外层引号并反转义内部引号得到原始 JSON。
  String _unwrapJsString(Object raw) {
    var s = raw.toString();
    if (s.length >= 2 && s.startsWith('"') && s.endsWith('"')) {
      s = s.substring(1, s.length - 1);
      s = s
          .replaceAll(r'\"', '"')
          .replaceAll(r'\\', r'\')
          .replaceAll(r'\/', '/');
    }
    return s;
  }
}
