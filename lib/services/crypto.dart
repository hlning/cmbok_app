import 'dart:convert';
import 'package:flutter/foundation.dart' hide Key;
import 'package:encrypt/encrypt.dart';

/// 日志工具
void _log(String message) {
  if (kDebugMode) {
    print('[ComicCrypto] $message');
  }
}

/// 拷贝漫画响应解密（对应 Python utils/base_utils.py analyze_data）
class ComicCrypto {
  static const _key = 'xxxmanga.woo.key';

  /// encData: 接口返回的加密字符串
  /// 返回解密后的 JSON 对象
  static Map<String, dynamic> analyzeData(String encData) {
    _log('=' * 50);
    _log('开始解密，数据长度: ${encData.length}');

    try {
      // 检查数据长度是否足够
      if (encData.length < 16) {
        _log('数据长度不足16，无法解密');
        return {};
      }

      final ivStr = encData.substring(0, 16);
      final cipherHex = encData.substring(16);

      _log('IV: $ivStr');
      _log('Cipher hex 长度: ${cipherHex.length}');

      final cipherBytes = _hexDecode(cipherHex);
      _log('Cipher bytes 长度: ${cipherBytes.length}');

      final iv = IV.fromUtf8(ivStr);
      final key = Key.fromUtf8(_key);
      final encrypter = Encrypter(AES(key, mode: AESMode.cbc));

      _log('开始解密...');
      final decrypted = encrypter.decrypt(Encrypted(cipherBytes), iv: iv);
      _log('解密成功，结果长度: ${decrypted.length}');
      _log(
        '解密内容前100字符: ${decrypted.substring(0, decrypted.length > 100 ? 100 : decrypted.length)}',
      );

      try {
        final jsonResult = jsonDecode(decrypted);
        _log('JSON 解析成功');
        return Map<String, dynamic>.from(jsonResult);
      } catch (e) {
        _log('JSON 解析失败: $e');
        return {};
      }
    } catch (e) {
      _log('解密失败: $e');
      _log('=' * 50);
      return {};
    }
  }

  static Uint8List _hexDecode(String hex) {
    _log('Hex 解码，长度: ${hex.length}');
    final out = Uint8List(hex.length ~/ 2);
    for (var i = 0; i < hex.length; i += 2) {
      out[i ~/ 2] = int.parse(hex.substring(i, i + 2), radix: 16);
    }
    return out;
  }
}
