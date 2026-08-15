import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:kindle_unpack/kindle_unpack.dart';

import 'package:cmbok_app/services/book_parser.dart';

void main() {
  // 用 kindle_unpack 自带 fixture（Mobi-7，Pride and Prejudice）验证：
  // toEpub 转出的 XHTML 是 HTML4（无引号属性/未闭合标签），xml 严格解析必失败，
  // 应走 html 回退解出章节，而非抛 "EPUB 无可读内容"。
  test('MOBI(Mobi-7) parseEpubBytes 经 html 回退解出章节', () {
    final fixture =
        'C:/Users/Administrator/AppData/Local/Pub/Cache/hosted/pub.dev/kindle_unpack-0.1.1/test/fixtures/pg1342.mobi';
    final bytes = File(fixture).readAsBytesSync();
    final book = KindleBook.fromBytes(bytes);
    final content = BookParser.parseEpubBytes(book.toEpub());

    expect(content.chapters, isNotEmpty, reason: 'MOBI HTML4 应走 html 回退解出章节');
    expect(content.chapters.first.blocks, isNotEmpty);
    expect(content.chapters.first.blocks.length, greaterThan(10));
  });
}
