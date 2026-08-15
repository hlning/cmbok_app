import 'dart:typed_data';

// gbk_codec 未导出映射表，只能取其 src；用于一次性反转构建平铺解码表。
// ignore: implementation_imports
import 'package:gbk_codec/src/gbk_maps.dart' show json_char_to_gbk;

/// 快速 GBK 解码。
///
/// `gbk_codec` 的 `gbk_bytes.decode` 用 `ret += char` 在循环里逐字拼接结果，
/// 是 O(n²)：7MB 中文 TXT 要几十秒，是 TXT 导入"加载很久"的根因。
///
/// 这里一次性把 gbk_codec 的 char→gbkcode 映射反转为平铺表
/// （索引 = 双字节 GBK 码 hi<<8|lo，值 = Unicode 码点），解码时 O(1) 查表、
/// 用 [String.fromCharCodes] 一次构造结果串，整体 O(n)：7MB 约 50~100ms。
///
/// 仅用于 TXT 全文解码；搜索等短串仍可直接用 `gbk_bytes`（n 小，O(n²) 可忽略）。
List<int>? _table;

List<int> _tableOf() {
  final t = _table;
  if (t != null) return t;
  final built = List<int>.filled(65536, 0xFFFD);
  json_char_to_gbk.forEach((char, code) {
    final rune = char.runes.isEmpty ? 0xFFFD : char.runes.first;
    if (code >= 0 && code < 65536) built[code] = rune;
  });
  _table = built;
  return built;
}

/// 解码 GBK 字节为字符串（O(n)）。
String decodeGbk(Uint8List bytes) {
  final table = _tableOf();
  final n = bytes.length;
  final out = Int32List(n);
  var j = 0;
  var i = 0;
  while (i < n) {
    final b = bytes[i];
    if (b < 0x80) {
      out[j++] = b;
      i++;
    } else if (i + 1 < n) {
      out[j++] = table[(b << 8) | bytes[i + 1]];
      i += 2;
    } else {
      out[j++] = 0xFFFD; // 孤立尾字节
      i++;
    }
  }
  return String.fromCharCodes(out, 0, j);
}
