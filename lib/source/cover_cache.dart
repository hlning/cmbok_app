// 封面落地缓存：加密（AES）/base64 站的封面 URL 无法直接显示
// （CachedNetworkImage 拿到的是密文/文本），下载还原后存本地缓存目录，
// 返回本地绝对路径。按 URL 哈希缓存，同 URL 只下一次；失败记入 _failed
// 本次运行内不再重试（调用方保留原 URL 兜底，展示端显示占位图）。

import 'dart:convert' show base64, utf8;
import 'dart:io' show Directory, File, Platform;

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

import 'image_restore.dart';
import 'site_config.dart';

void _log(String message) {
  if (kDebugMode) {
    debugPrint('[SourceCoverCache] $message');
  }
}

class SourceCoverCache {
  SourceCoverCache._();
  static final SourceCoverCache instance = SourceCoverCache._();

  final Dio _dio = Dio(
    BaseOptions(
      responseType: ResponseType.bytes,
      connectTimeout: const Duration(seconds: 15),
      receiveTimeout: const Duration(seconds: 20),
      headers: {
        'User-Agent':
            'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
            '(KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36',
      },
    ),
  );

  /// 进行中的下载（同 URL 去重并发）
  final Map<String, Future<String?>> _pending = {};

  /// 本次运行已失败的 URL，不再重试
  final Set<String> _failed = {};

  Future<Directory> get _dir async {
    final dir = Directory(
      '${(await getTemporaryDirectory()).path}/cover_cache',
    );
    if (!await dir.exists()) await dir.create(recursive: true);
    return dir;
  }

  /// 封面落地：下载还原后存缓存目录，返回本地绝对路径。
  /// 站点未配还原（非加密/base64）或下载失败返回 null。
  Future<String?> localize(String url, SiteConfig site) async {
    if (!url.startsWith('http')) return null;
    if (!needsRestore(site)) return null;
    if (_failed.contains(url)) return null;
    final running = _pending[url];
    if (running != null) return running;
    final f = _doLocalize(url, site);
    _pending[url] = f;
    try {
      return await f;
    } finally {
      _pending.remove(url);
    }
  }

  /// 站点封面是否需要落地还原（AES 加密或 base64 文本）
  static bool needsRestore(SiteConfig site) =>
      site.imgAesKey.isNotEmpty || site.imgBodyBase64;

  Future<String?> _doLocalize(String url, SiteConfig site) async {
    try {
      final dir = await _dir;
      final key = _cacheKey(url);
      // 已缓存（扩展名未知，逐一探测）
      for (final ext in const ['.jpg', '.png', '.webp', '.gif']) {
        final f = File('${dir.path}${Platform.pathSeparator}$key$ext');
        if (await f.exists()) return f.path;
      }
      final resp = await _dio.get<List<int>>(
        url,
        options: Options(headers: {'Referer': site.url}),
      );
      var bytes = resp.data ?? const <int>[];
      if (bytes.isEmpty) throw Exception('空响应');
      if (site.imgBodyBase64) {
        // 响应体是 base64 文本（bytes 即 ASCII）
        final text = utf8.decode(bytes, allowMalformed: true);
        bytes = base64.decode(text.replaceAll(RegExp(r'\s'), ''));
      }
      final out = restoreImageBytes(bytes, aesKeyBytes(site.imgAesKey));
      final file = File(
        '${dir.path}${Platform.pathSeparator}$key${imageExtOf(out)}',
      );
      await file.writeAsBytes(out, flush: true);
      return file.path;
    } catch (e) {
      _failed.add(url);
      _log('封面落地失败 $url: $e');
      return null;
    }
  }

  /// 缓存键：URL 哈希的十六进制（同一 app 版本内稳定，升级后失效重下无害）
  String _cacheKey(String url) {
    final h = url.hashCode;
    return (h & 0x7fffffff).toRadixString(16);
  }
}
