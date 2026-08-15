import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';

void _log(String message) {
  if (kDebugMode) debugPrint('[BookFont] $message');
}

/// 用户自定义正文字体的描述。family 由 [FontLoader] 注册，
/// 直接用于 [BookTypography.fontFamily] 与渲染端 [TextStyle.fontFamily]。
class UserFont {
  final String family; // FontLoader 注册名 = 文件名(去后缀)
  final String displayName; // UI 显示名 = 文件名(去后缀)
  final String path; // 源 ttf/otf/ttc 路径
  const UserFont({
    required this.family,
    required this.displayName,
    required this.path,
  });
}

/// 图书正文字体管理（单例 + ChangeNotifier）。
///
/// 启动扫描 [fontsDir]/ 复制到此的 .ttf/.otf/.ttc，统一用 [FontLoader]
/// 异步注册（FamilyName = 文件名去后缀）。UI 通过 [availableFamilies] 拿到
/// 已注册的 family 字符串列表，再写入 SettingsService/ReaderOverride。
///
/// 内置 family：
/// - `null`（"跟随阅读模式"）— 仿真 → inkReadingKai，普通 → 系统
/// - `"system"`（"系统默认"）— 强制系统字体
/// - `"inkReadingKai"` — 内置水墨楷体（pubspec 已声明）
class BookFontService extends ChangeNotifier {
  BookFontService._();
  static final BookFontService _instance = BookFontService._();
  factory BookFontService() => _instance;

  /// "系统默认" 项的哨兵 family。选它等于显式用系统字体（与 null 的
  /// "跟随阅读模式"区分），写入偏好后 fontFamily = 'system'，渲染端会还原成
  /// null 传给 TextStyle（见 ReaderOverrideService.effectiveBookFontFamilyResolve）。
  static const systemFamily = 'system';

  /// "跟随阅读模式" 项的哨兵 family（仅 UI 用，不写入 typo；写入偏好时存 null）。
  static const autoFamily = '__auto__';

  /// 内置静态选项（不依赖运行时扫描）。
  static const builtinOptions = <(String family, String label)>[
    (autoFamily, '跟随阅读模式'),
    (systemFamily, '系统默认'),
    ('inkReadingKai', '水墨楷体'),
  ];

  /// 应用启动扫描注册后的全部 family 列表（包括用户字体）。
  /// 与 [fontByFamily] 同步；UI 用此列表渲染字体选项。
  List<String> _userFamilies = const [];
  List<String> get userFamilies => List.unmodifiable(_userFamilies);

  /// family -> 用户字体描述（仅用户字体有；内置 family 不在此）。
  final Map<String, UserFont> _fontByFamily = {};
  Map<String, UserFont> get fontByFamily =>
      Map<String, UserFont>.unmodifiable(_fontByFamily);

  /// 扫描已注册用户字体是否就绪（init 完成）。UI 在字体项变更前可查询，
  /// 避免在首帧就拿空列表（如 App 进阅读器前的快速进入路径已基本无影响）。
  bool _ready = false;
  bool get ready => _ready;

  Future<Directory> _fontsDir() async {
    final appDir = await getApplicationDocumentsDirectory();
    final d = Directory('${appDir.path}/book_fonts');
    if (!d.existsSync()) await d.create(recursive: true);
    return d;
  }

  /// 启动调用：扫描字体目录、加载所有已导入的字体。
  Future<void> init() async {
    try {
      final dir = await _fontsDir();
      final entries = dir.listSync(followLinks: false);
      final files = <File>[];
      for (final e in entries) {
        if (e is! File) continue;
        final name = e.uri.pathSegments.last;
        final ext = name.toLowerCase();
        if (!ext.endsWith('.ttf') &&
            !ext.endsWith('.otf') &&
            !ext.endsWith('.ttc')) {
          continue;
        }
        files.add(e);
      }
      if (files.isNotEmpty) {
        final loader = FontLoader('book_fonts');
        final list = <UserFont>[];
        for (final e in files) {
          final name = e.uri.pathSegments.last;
          final base = _stripExt(name);
          final bytes = await e.readAsBytes();
          loader.addFont(Future<ByteData>.value(ByteData.sublistView(bytes)));
          list.add(
            UserFont(family: base, displayName: base, path: e.path),
          );
        }
        await loader.load();
        for (final f in list) {
          _fontByFamily[f.family] = f;
        }
        _userFamilies = list.map((f) => f.family).toList()..sort();
      }
      _ready = true;
      _log('init 完成 用户字体=${_userFamilies.length}');
      notifyListeners();
    } catch (e) {
      _ready = true;
      _log('init 失败: $e');
    }
  }

  /// 通过 file_picker 导入本地字体文件。复制到 [fontsDir]、用 FontLoader
  /// 注册后 notify。重名覆盖现有字体并替换文件，已注册的旧 family 不卸载
  /// （Flutter 无卸载 API），但同名新文件覆盖后下次度量会用新文件特征。
  ///
  /// 返回注册后的 family 名；失败返回 null（UI 自行提示）。
  ///
  /// type=FileType.custom + allowedExtensions 用于部分 ROM 的 SAF 兼容
  /// （见 bookshelf_page._importLocalBook 同模式）。
  Future<String?> importFont() async {
    try {
      final result = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowMultiple: false,
        allowedExtensions: const ['ttf', 'otf', 'ttc'],
      );
      if (result == null || result.files.isEmpty) return null;
      final picked = result.files.single;
      final srcPath = picked.path;
      if (srcPath == null) return null;
      final src = File(srcPath);
      if (!await src.exists()) return null;
      final name = picked.name; // 已含后缀
      final base = _stripExt(name);
      final dir = await _fontsDir();
      final dst = File('${dir.path}/$name');
      await dst.writeAsBytes(await src.readAsBytes());

      final loader = FontLoader('book_fonts_$base');
      final bd = await dst.readAsBytes();
      loader.addFont(
        Future<ByteData>.value(ByteData.sublistView(bd)),
      );
      await loader.load();
      _fontByFamily[base] = UserFont(
        family: base,
        displayName: base,
        path: dst.path,
      );
      _userFamilies = _fontByFamily.keys.toList()..sort();
      _log('importFont $base');
      notifyListeners();
      return base;
    } catch (e) {
      _log('importFont 失败: $e');
      return null;
    }
  }

  String _stripExt(String name) {
    final dot = name.lastIndexOf('.');
    return dot <= 0 ? name : name.substring(0, dot);
  }
}