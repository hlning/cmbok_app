import 'dart:io';

import 'package:flutter_cache_manager/flutter_cache_manager.dart';
import 'package:http/io_client.dart';

/// 漫画图片专用缓存管理器。
///
/// 背景：dart:io HttpClient 跨域重定向时**不保留 req.headers 的 User-Agent**，
/// 改用 client.userAgent（默认 "Dart/xxx"）。flutter_cache_manager 只设 req.headers
/// UA 不设 client.userAgent，导致重定向后 UA 退化为 Dart 默认 -> 某些 CDN 拦 bot UA
/// 返 403（如 lmanhua g-mh.online 301 到 c-nd3-1.6wm.top，c-nd3 对非浏览器 UA 403）。
///
/// 此处给 IOClient 的 HttpClient 设浏览器 UA，使重定向后仍带浏览器 UA。
/// 各源 imageHeaders 的 UA 一致（desktop Chrome），全局复用本管理器。
final CacheManager comicImageCacheManager = CacheManager(
  Config(
    'comicImages',
    fileService: HttpFileService(
      httpClient: IOClient(
        HttpClient()
          ..userAgent =
              'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
              '(KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36',
      ),
    ),
  ),
);
