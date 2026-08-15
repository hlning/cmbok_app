// 一次性 spike：验证 Dart/dio 能否连通 z-library（TLS 指纹/Cloudflare 风险）。
// 验证通过后可删除。运行：flutter test test/zlibrary_spike_test.dart
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:cmbok_app/models/search_result.dart';
import 'package:cmbok_app/services/zlibrary_service.dart';

void main() {
  test('z-library 内置账号登录 + 搜索 + 下载链接', () async {
    SharedPreferences.setMockInitialValues({});
    final svc = ZlibraryService();
    await svc.init();
    debugPrint('[spike] domain=${svc.domain}, loggedIn=${svc.isLoggedIn}');

    // 1. 搜索（内部会用内置账号登录）
    SearchResult result;
    try {
      result = await svc.search('三体', limit: 3);
    } catch (e) {
      debugPrint('[spike] 搜索抛异常: $e');
      rethrow;
    }
    debugPrint(
      '[spike] 搜索成功: ${result.items.length} 条, total=${result.total}, '
      'page=${result.currentPage}/${result.totalPages}',
    );
    expect(result.items, isNotEmpty);

    final book = result.items.first;
    debugPrint(
      '[spike] 首本: id=${book.id} hash=${book.hash} title=${book.title} '
      'author=${book.author} ext=${book.extension} size=${book.filesizeString}',
    );

    // 2. 下载链接（仅信息性：内置账号在 z-library 侧可能已达限额，不强制断言）
    try {
      final link = await svc.getDownloadLink(book.id, book.hash);
      debugPrint('[spike] 下载链接: ${link.filename} -> ${link.url}');
    } on ZlibraryException catch (e) {
      debugPrint(
        '[spike] 下载链接失败: ${e.code} ${e.message}（账号可能已达 z-library 侧限额）',
      );
    }
  }, timeout: const Timeout(Duration(seconds: 90)));
}
