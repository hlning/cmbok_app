// 在线阅读 WebView 页：注入 z-library 登录 cookie 后加载 readOnlineUrl，
// 免去在外部浏览器重新登录。桌面端（webview_flutter 无平台实现）降级外部浏览器。

import 'dart:io' show Platform;

import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:webview_flutter/webview_flutter.dart';

import '../services/zlibrary_service.dart';

class OnlineReaderPage extends StatefulWidget {
  final String url;
  final String? title;

  const OnlineReaderPage({super.key, required this.url, this.title});

  @override
  State<OnlineReaderPage> createState() => _OnlineReaderPageState();
}

class _OnlineReaderPageState extends State<OnlineReaderPage> {
  late final WebViewController _controller;
  bool _loading = true;
  int _progress = 0;

  @override
  void initState() {
    super.initState();
    // 桌面端无 webview_flutter 平台实现，降级到外部浏览器（无 cookie，可能需重登）
    if (!Platform.isAndroid && !Platform.isIOS) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _openExternal());
      return;
    }
    _controller = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setNavigationDelegate(
        NavigationDelegate(
          onProgress: (p) => setState(() => _progress = p),
          onPageStarted: (_) {
            if (mounted) setState(() => _loading = true);
          },
          onPageFinished: (_) {
            if (mounted) setState(() => _loading = false);
          },
          onWebResourceError: (e) {
            if (mounted) setState(() => _loading = false);
            _toast('加载失败：${e.description}');
          },
        ),
      );
    _injectCookieAndLoad();
  }

  /// 注入登录 cookie 后加载阅读页。cookie 必须在 loadRequest 之前 set；
  /// domain 带前导点以覆盖子域（remix cookie 可能 HttpOnly，必须走 cookieManager）。
  Future<void> _injectCookieAndLoad() async {
    final z = ZlibraryService();
    final domain = z.domain;
    final cookieManager = WebViewCookieManager();
    for (final entry in z.cookiesForWebview().entries) {
      await cookieManager.setCookie(
        WebViewCookie(
          name: entry.key,
          value: entry.value,
          domain: '.$domain',
          path: '/',
        ),
      );
    }
    try {
      await _controller.loadRequest(Uri.parse(widget.url));
    } catch (e) {
      _toast('链接无效：$e');
    }
  }

  Future<void> _openExternal() async {
    final uri = Uri.tryParse(widget.url);
    if (uri == null) {
      _toast('链接无效');
    } else {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    }
    if (mounted) Navigator.of(context).maybePop();
  }

  void _toast(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text(msg),
          duration: const Duration(seconds: 2),
          behavior: SnackBarBehavior.floating,
        ),
      );
  }

  @override
  Widget build(BuildContext context) {
    // 桌面端占位（initState 已调度外部浏览器打开）
    if (!Platform.isAndroid && !Platform.isIOS) {
      return Scaffold(
        appBar: AppBar(title: Text(widget.title ?? '在线阅读')),
        body: const Center(child: Text('已用外部浏览器打开')),
      );
    }
    return Scaffold(
      appBar: AppBar(title: Text(widget.title ?? '在线阅读')),
      body: Stack(
        children: [
          WebViewWidget(controller: _controller),
          if (_loading)
            Positioned(
              top: 0,
              left: 0,
              right: 0,
              child: LinearProgressIndicator(
                value: _progress > 0 ? _progress / 100 : null,
                minHeight: 2,
              ),
            ),
        ],
      ),
    );
  }
}
