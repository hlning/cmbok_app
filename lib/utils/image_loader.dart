import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:dio/dio.dart';
import 'package:path_provider/path_provider.dart';

/// 带缓存的图片加载器
class ImageLoader {
  static final ImageLoader _instance = ImageLoader._();
  factory ImageLoader() => _instance;
  ImageLoader._();

  final Dio _dio = Dio(
    BaseOptions(
      connectTimeout: const Duration(seconds: 15),
      receiveTimeout: const Duration(seconds: 30),
    ),
  );

  final Map<String, Uint8List> _memoryCache = {};
  final int _maxMemoryCache = 100;

  /// 获取应用缓存目录
  Future<String> get _cacheDir async {
    final dir = await getTemporaryDirectory();
    final cacheDir = Directory('${dir.path}/cmbok_images');
    if (!await cacheDir.exists()) {
      await cacheDir.create(recursive: true);
    }
    return cacheDir.path;
  }

  /// 生成缓存文件名
  String _cacheFileName(String url) {
    final bytes = utf8.encode(url);
    final hash = _simpleHash(bytes);
    return 'img_$hash';
  }

  int _simpleHash(List<int> bytes) {
    var hash = 0;
    for (final b in bytes) {
      hash = ((hash << 5) - hash) + b;
      hash = hash & hash;
    }
    return hash.abs();
  }

  /// 加载图片（内存缓存 -> 磁盘缓存 -> 网络）
  Future<Uint8List> loadImage(String url, {bool forceRefresh = false}) async {
    // 1. 内存缓存
    if (!forceRefresh && _memoryCache.containsKey(url)) {
      return _memoryCache[url]!;
    }

    // 2. 磁盘缓存
    final cacheFile = File('${await _cacheDir}/${_cacheFileName(url)}');
    if (!forceRefresh && await cacheFile.exists()) {
      final bytes = await cacheFile.readAsBytes();
      _addToMemoryCache(url, bytes);
      return bytes;
    }

    // 3. 网络下载
    final response = await _dio.get(
      url,
      options: Options(
        responseType: ResponseType.bytes,
        headers: {
          'User-Agent':
              'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36',
          'Referer': 'https://2025copy.com/',
        },
      ),
    );

    final bytes = response.data as Uint8List;

    // 写入磁盘缓存
    await cacheFile.writeAsBytes(bytes);

    // 加入内存缓存
    _addToMemoryCache(url, bytes);

    return bytes;
  }

  void _addToMemoryCache(String url, Uint8List bytes) {
    if (_memoryCache.length >= _maxMemoryCache) {
      _memoryCache.remove(_memoryCache.keys.first);
    }
    _memoryCache[url] = bytes;
  }

  /// 清空内存缓存
  void clearMemoryCache() {
    _memoryCache.clear();
  }

  /// 清空磁盘缓存
  Future<void> clearDiskCache() async {
    final dir = Directory(await _cacheDir);
    if (await dir.exists()) {
      await dir.delete(recursive: true);
    }
  }

  /// 获取缓存大小
  Future<int> getCacheSize() async {
    final dir = Directory(await _cacheDir);
    if (!await dir.exists()) return 0;

    int size = 0;
    await for (final entity in dir.list()) {
      if (entity is File) {
        size += await entity.length();
      }
    }
    return size;
  }
}
