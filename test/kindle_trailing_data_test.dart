import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:kindle_unpack/kindle_unpack.dart';

void main() {
  // 回归：extraDataFlags bit0（多字节重叠指示）置位但某条文本记录过短（典型为
  // 空的末条记录）时，kindle_unpack 0.1.1 原版会抛 'multibyte-overlap indicator
  // points before record start' 致整本 MOBI 打不开。本地补丁改为容错跳过。
  group('trailing_data 容错', () {
    test('空记录 + flags=1 不再抛 HeaderException（size 返回 0）', () {
      expect(sizeOfTrailingDataEntries(Uint8List(0), 0x1), 0);
    });

    test('空记录 + flags=1 剥离后为空视图', () {
      expect(stripTrailingDataEntries(Uint8List(0), 0x1).length, 0);
    });

    // 正向用例：正常的多字节重叠剥离不受补丁影响（取自 kindle_unpack 自带用例）。
    // 末字节 0x01 -> overlap = (0x01 & 0x3) + 1 = 2，剥离末 2 字节。
    test('正常记录 + flags=1 仍正确剥离末 2 字节', () {
      final out = stripTrailingDataEntries(
        Uint8List.fromList([0x41, 0x42, 0x43, 0xFF, 0x01]),
        0x1,
      );
      expect(out, [0x41, 0x42, 0x43]);
    });

    // 回归：bit1（长度前缀尾部条目）置位、记录末尾字节解出超大 varint
    // (0x7F | 0x7F<<7 | 0x7F<<14 = 2097151) 超过记录长度时，原版抛
    // 'trailing-data size ... out of range'；补丁后返回空，避免整书失败。
    test('尾部数据尺寸越界时返回空而非抛错', () {
      final out = stripTrailingDataEntries(
        Uint8List.fromList([0x41, 0xFF, 0x7F, 0x7F]),
        0x2,
      );
      expect(out.length, 0);
    });
  });
}
