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

import 'package:flutter/material.dart';
import 'package:webview_flutter/webview_flutter.dart';

import 'site_config.dart';

void _log(String message) {
  debugPrint('[WebViewImageFetcher] $message');
}

class WebViewImageFetcher {
  static final WebViewImageFetcher _instance = WebViewImageFetcher._();
  factory WebViewImageFetcher() => _instance;
  WebViewImageFetcher._();

  late final WebViewController controller;
  bool _initialized = false;

  /// 串行化：fetch 依次排队执行，_last 完成后才跑下一个
  Future<void> _last = Future.value();

  void init() {
    if (_initialized) return;
    controller = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setNavigationDelegate(
        NavigationDelegate(
          onPageFinished: (_) => _pageCompleter?.complete(),
          onWebResourceError: (e) {
            _log('资源错误: ${e.description}');
            _pageCompleter?.completeError(Exception(e.description));
          },
        ),
      );
    _initialized = true;
  }

  Completer<void>? _pageCompleter;

  /// 根树挂载的 1px 隐藏 WebView（放 Stack 最底层，被上层覆盖不可见）。
  /// 1px 可见尺寸确保 Android/iOS 平台视图正常创建与加载（Offstage/0 尺寸可能不运行）。
  Widget buildHiddenWebView() {
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
  Future<dynamic> _runAsyncScript(String scriptBody) async {
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

    // TODO(2b): imgLoadMode=3（下一页）站一页一图，需循环 next_page 翻页合并。
    //   2a 验证站（MYCOMIC/咚漫）均为 mode 2，快取可一次拿全；mode 3 暂返回当前页。
    if (site.imgLoadMode == 3) {
      _log('imgLoadMode=3（下一页）暂未实现翻页，仅取当前页');
    }

    return _extract(site);
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
    // outerHTML 经 JSON.stringify -> _unwrapJsString -> jsonDecode 还原
    // （正确处理换行/引号/反斜杠转义，避免 _unwrapJsString 漏转 \n 等）
    final raw = await controller.runJavaScriptReturningResult(
      'JSON.stringify(document.documentElement.outerHTML)',
    );
    return jsonDecode(_unwrapJsString(raw)) as String;
  }

  Future<List<String>> _extract(SiteConfig site) async {
    // imgScript 优先（配置驱动，适用加密/JS 渲染站）；失败或返回空则重试（等 JS
    // 就绪），仍失败回退通用快取。
    if (site.imgScript.isNotEmpty) {
      for (var attempt = 1; attempt <= 3; attempt++) {
        try {
          final imgs = await _runScript(_imgScriptBody(site.imgScript));
          if (imgs.isNotEmpty) {
            _log(
              'imgScript 取到 ${imgs.length} 张（尝试 $attempt）: ${imgs.take(2).join(", ")}',
            );
            return imgs;
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
      _log('imgScript 3 次均失败/空，回退通用快取');
    }
    final imgs = await _runScript(_scanScriptBody(site));
    _log('通用快取取到 ${imgs.length} 张: ${imgs.take(2).join(", ")}');
    return imgs;
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
    final inject =
        '''
(function(){
  try {
    var result = ($scriptBody);
    window._fetchResult = (result === null || result === undefined) ? [] : result;
    window._fetchDone = true;
  } catch(e) {
    window._fetchResult = { "__error": e && e.message ? e.message : String(e) };
    window._fetchDone = true;
  }
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
    return '(function(){'
        'var raw = (function(ifr){ $imgScript })({contentWindow: window});'
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
      var a = imgAttr ? (imgs[i].getAttribute(imgAttr) || '') : (imgs[i].src || '');
      if (a && a.indexOf('data:')!==0) {
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
