// 章节图/封面字节还原共享工具：明文直过、AES-CBC（前 16 字节 IV + 密文，
// PKCS7 去填充）解密。WebViewImageFetcher 直下路径与 SourceCoverCache 共用。

import 'dart:convert' show utf8;
import 'dart:typed_data' show Uint8List;

import 'package:encrypt/encrypt.dart' as enc;

/// 常见图片魔数（JPEG/PNG/GIF/BMP/RIFF-WebP）
bool isImageMagic(List<int> b) =>
    b.length > 4 &&
    ((b[0] == 0xFF && b[1] == 0xD8) ||
        (b[0] == 0x89 && b[1] == 0x50) ||
        (b[0] == 0x47 && b[1] == 0x49) ||
        (b[0] == 0x42 && b[1] == 0x4D) ||
        (b[0] == 0x52 && b[1] == 0x49 && b[2] == 0x46 && b[3] == 0x46));

/// 还原章节图/封面字节：已是明文图片直接返回；否则按 AES-CBC 解密。
/// [key32] 为空且非明文时抛异常；解密后仍非图片魔数抛异常（不产出坏文件）。
List<int> restoreImageBytes(List<int> bytes, Uint8List? key32) {
  if (isImageMagic(bytes)) return bytes;
  if (key32 == null) throw Exception('非明文图片且未配密钥');
  if (bytes.length <= 32) throw Exception('密文过短');
  final iv = enc.IV(Uint8List.fromList(bytes.sublist(0, 16)));
  final ct = Uint8List.fromList(bytes.sublist(16));
  final out =
      enc.Encrypter(enc.AES(enc.Key(key32), mode: enc.AESMode.cbc, padding: null))
          .decryptBytes(enc.Encrypted(ct), iv: iv);
  // 手动去 PKCS7 填充（与站点 crypto.subtle.decrypt 一致）
  final pad = out.isNotEmpty ? out.last : 0;
  if (pad > 0 && pad <= 16 && pad <= out.length) {
    var valid = true;
    for (var k = out.length - pad; k < out.length; k++) {
      if (out[k] != pad) {
        valid = false;
        break;
      }
    }
    if (valid) out.removeRange(out.length - pad, out.length);
  }
  if (!isImageMagic(out)) throw Exception('解密后非图片');
  return out;
}

/// 从图片字节推断扩展名（默认 .jpg）
String imageExtOf(List<int> b) {
  if (b.length > 4) {
    if (b[0] == 0x89 && b[1] == 0x50) return '.png';
    if (b[0] == 0x47 && b[1] == 0x49) return '.gif';
    if (b[0] == 0x52 && b[1] == 0x49 && b[2] == 0x46 && b[3] == 0x46) {
      return '.webp';
    }
  }
  return '.jpg';
}

/// 取 AES 密钥的 utf-8 前 32 字节（不足 32 返回 null）
Uint8List? aesKeyBytes(String key) {
  if (key.isEmpty) return null;
  final kb = utf8.encode(key);
  if (kb.length < 32) return null;
  return Uint8List.fromList(kb.sublist(0, 32));
}
