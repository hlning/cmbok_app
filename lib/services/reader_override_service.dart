import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'book_font_service.dart';
import 'settings_service.dart';

void _log(String message) {
  if (kDebugMode) {
    debugPrint('[ReaderOverride] $message');
  }
}

/// 阅读器「独立设置」覆盖服务（单例 + ChangeNotifier）。
///
/// 在阅读器内开启「独立设置」后，该本漫画/图书的阅读设置仅对自身生效，
/// 不影响全局；关闭则回退全局设置（[SettingsService]）。
///
/// 持久化为两张 JSON map（key 存在 = 独立设置 ON，用覆盖值；缺失 = OFF，用全局）：
/// - 漫画：`reader_override_manga` = { pathWord: {mode:int, preload:int, reverseTap:bool, doublePage:bool, showHud:bool, volumeKeyTurn:bool} }
/// - 图书：`reader_override_book` = { bookId: {mode:int, fontSize, lineHeight, hPad, vPad, fontFamily, reverseTap:bool, doublePage:bool, showHud:bool, volumeKeyTurn:bool} }
///
/// 与 [ReadingProgressService] / [BookReadingProgressService] 一样按
/// pathWord / bookId 隔离，零回归全局设置。
class ReaderOverrideService extends ChangeNotifier {
  ReaderOverrideService._();
  static final ReaderOverrideService _instance = ReaderOverrideService._();
  factory ReaderOverrideService() => _instance;

  static const _mangaKey = 'reader_override_manga';
  static const _bookKey = 'reader_override_book';

  /// 漫画 per-item 覆盖：pathWord -> {mode, preload, reverseTap, doublePage, showHud, volumeKeyTurn}
  final Map<String, Map<String, dynamic>> _manga = {};

  /// 图书 per-item 覆盖：bookId -> {mode, fontSize, lineHeight, hPad, vPad, fontFamily, reverseTap, doublePage, showHud, volumeKeyTurn}
  final Map<String, Map<String, dynamic>> _book = {};

  Future<void> init() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final mRaw = prefs.getString(_mangaKey);
      if (mRaw != null) {
        final obj = jsonDecode(mRaw) as Map<String, dynamic>;
        for (final e in obj.entries) {
          if (e.value is Map) {
            _manga[e.key] = Map<String, dynamic>.from(e.value as Map);
          }
        }
      }
      final bRaw = prefs.getString(_bookKey);
      if (bRaw != null) {
        final obj = jsonDecode(bRaw) as Map<String, dynamic>;
        for (final e in obj.entries) {
          if (e.value is Map) {
            _book[e.key] = Map<String, dynamic>.from(e.value as Map);
          }
        }
      }
      _log('已加载 漫画覆盖=${_manga.length} 图书覆盖=${_book.length}');
    } catch (e) {
      _log('加载阅读器覆盖失败: $e');
    }
    notifyListeners();
  }

  Future<void> _persistManga() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_mangaKey, jsonEncode(_manga));
    } catch (e) {
      _log('保存漫画覆盖失败: $e');
    }
  }

  Future<void> _persistBook() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_bookKey, jsonEncode(_book));
    } catch (e) {
      _log('保存图书覆盖失败: $e');
    }
  }

  // ============ 漫画 ============

  bool isIndependentManga(String pathWord) => _manga.containsKey(pathWord);

  ReadingMode effectiveMangaMode(String pathWord) {
    final m = _manga[pathWord];
    if (m != null) {
      final idx = m['mode'];
      if (idx is int && idx >= 0 && idx < ReadingMode.values.length) {
        return ReadingMode.values[idx];
      }
    }
    return SettingsService().readingMode;
  }

  int effectivePreload(String pathWord) {
    final m = _manga[pathWord];
    if (m != null && m['preload'] is int) return m['preload'] as int;
    return SettingsService().preloadImageCount;
  }

  bool effectiveReverseTapManga(String pathWord) {
    final m = _manga[pathWord];
    if (m != null && m['reverseTap'] is bool) return m['reverseTap'] as bool;
    return SettingsService().reverseTap;
  }

  bool effectiveDoublePageManga(String pathWord) {
    final m = _manga[pathWord];
    if (m != null && m['doublePage'] is bool) return m['doublePage'] as bool;
    return SettingsService().doublePage;
  }

  bool effectiveShowHudManga(String pathWord) {
    final m = _manga[pathWord];
    if (m != null && m['showHud'] is bool) return m['showHud'] as bool;
    return SettingsService().showReaderHud;
  }

  bool effectiveVolumeKeyTurnManga(String pathWord) {
    final m = _manga[pathWord];
    if (m != null && m['volumeKeyTurn'] is bool) {
      return m['volumeKeyTurn'] as bool;
    }
    return SettingsService().volumeKeyTurn;
  }

  /// 开/关漫画独立设置：开 = 用当前全局快照建条目；关 = 删条目（回退全局）。
  Future<void> setIndependentManga(String pathWord, bool value) async {
    final exists = _manga.containsKey(pathWord);
    if (value && !exists) {
      final s = SettingsService();
      _manga[pathWord] = {
        'mode': s.readingMode.index,
        'preload': s.preloadImageCount,
        'reverseTap': s.reverseTap,
        'doublePage': s.doublePage,
        'showHud': s.showReaderHud,
        'volumeKeyTurn': s.volumeKeyTurn,
      };
      notifyListeners();
      await _persistManga();
    } else if (!value && exists) {
      _manga.remove(pathWord);
      notifyListeners();
      await _persistManga();
    }
  }

  Future<void> setMangaMode(String pathWord, ReadingMode mode) async {
    if (_manga.containsKey(pathWord)) {
      if (_manga[pathWord]!['mode'] == mode.index) return;
      _manga[pathWord]!['mode'] = mode.index;
      notifyListeners();
      await _persistManga();
    } else {
      await SettingsService().setReadingMode(mode);
    }
  }

  Future<void> setMangaPreload(String pathWord, int count) async {
    if (_manga.containsKey(pathWord)) {
      if (_manga[pathWord]!['preload'] == count) return;
      _manga[pathWord]!['preload'] = count;
      notifyListeners();
      await _persistManga();
    } else {
      await SettingsService().setPreloadImageCount(count);
    }
  }

  Future<void> setMangaReverseTap(String pathWord, bool value) async {
    if (_manga.containsKey(pathWord)) {
      if (_manga[pathWord]!['reverseTap'] == value) return;
      _manga[pathWord]!['reverseTap'] = value;
      notifyListeners();
      await _persistManga();
    } else {
      await SettingsService().setReverseTap(value);
    }
  }

  Future<void> setMangaDoublePage(String pathWord, bool value) async {
    if (_manga.containsKey(pathWord)) {
      if (_manga[pathWord]!['doublePage'] == value) return;
      _manga[pathWord]!['doublePage'] = value;
      notifyListeners();
      await _persistManga();
    } else {
      await SettingsService().setDoublePage(value);
    }
  }

  Future<void> setMangaShowHud(String pathWord, bool value) async {
    if (_manga.containsKey(pathWord)) {
      if (_manga[pathWord]!['showHud'] == value) return;
      _manga[pathWord]!['showHud'] = value;
      notifyListeners();
      await _persistManga();
    } else {
      await SettingsService().setShowReaderHud(value);
    }
  }

  Future<void> setMangaVolumeKeyTurn(String pathWord, bool value) async {
    if (_manga.containsKey(pathWord)) {
      if (_manga[pathWord]!['volumeKeyTurn'] == value) return;
      _manga[pathWord]!['volumeKeyTurn'] = value;
      notifyListeners();
      await _persistManga();
    } else {
      await SettingsService().setVolumeKeyTurn(value);
    }
  }

  // ============ 图书 ============

  bool isIndependentBook(String bookId) => _book.containsKey(bookId);

  BookReadingMode effectiveBookMode(String bookId) {
    final m = _book[bookId];
    if (m != null) {
      final idx = m['mode'];
      if (idx is int && idx >= 0 && idx < BookReadingMode.values.length) {
        return BookReadingMode.values[idx];
      }
    }
    return SettingsService().bookReadingMode;
  }

  double effectiveBookFontSize(String bookId) {
    final m = _book[bookId];
    if (m != null && m['fontSize'] is num) {
      return (m['fontSize'] as num).toDouble();
    }
    return SettingsService().bookFontSize;
  }

  double effectiveBookLineHeight(String bookId) {
    final m = _book[bookId];
    if (m != null && m['lineHeight'] is num) {
      return (m['lineHeight'] as num).toDouble();
    }
    return SettingsService().bookLineHeight;
  }

  double effectiveBookHorizontalPadding(String bookId) {
    final m = _book[bookId];
    if (m != null && m['hPad'] is num) return (m['hPad'] as num).toDouble();
    return SettingsService().bookHorizontalPadding;
  }

  double effectiveBookVerticalPadding(String bookId) {
    final m = _book[bookId];
    if (m != null && m['vPad'] is num) return (m['vPad'] as num).toDouble();
    return SettingsService().bookVerticalPadding;
  }

  bool effectiveReverseTapBook(String bookId) {
    final m = _book[bookId];
    if (m != null && m['reverseTap'] is bool) return m['reverseTap'] as bool;
    return SettingsService().reverseTap;
  }

  bool effectiveDoublePageBook(String bookId) {
    final m = _book[bookId];
    if (m != null && m['doublePage'] is bool) return m['doublePage'] as bool;
    return SettingsService().doublePage;
  }

  bool effectiveShowHudBook(String bookId) {
    final m = _book[bookId];
    if (m != null && m['showHud'] is bool) return m['showHud'] as bool;
    return SettingsService().showReaderHud;
  }

  bool effectiveVolumeKeyTurnBook(String bookId) {
    final m = _book[bookId];
    if (m != null && m['volumeKeyTurn'] is bool) {
      return m['volumeKeyTurn'] as bool;
    }
    return SettingsService().volumeKeyTurn;
  }

  /// 生效的图书正文字体（直接 family 字符串，未还原为 null）。
  /// 调用方需进一步处理 'system' / 'inkReadingKai' / auto 三种语义：
  /// - 见 [effectiveBookFontFamilyResolved]，按渲染端需要的 String? 还原。
  String? effectiveBookFontFamily(String bookId) {
    final m = _book[bookId];
    if (m != null && m['fontFamily'] is String?) {
      final v = m['fontFamily'];
      if (v is String && v.isEmpty) return null;
      return v as String?;
    }
    return SettingsService().bookFontFamily;
  }

  /// 还原为渲染端可用的 FontFamily：
  /// - `null`（= 跟随阅读模式）：仿真 → `inkReadingKai`，普通 → `null`（系统）
  /// - `'system'`（= 系统默认）：一律 `null`（即便仿真也用系统字体）
  /// - 其他（`'inkReadingKai'` 或用户自定义 family）：原样返回
  ///
  /// [mode] 为当前生效的图书阅读模式，由调用方传入。
  static String? resolveFontFamily(String? family, BookReadingMode mode) {
    if (family == null || family.isEmpty) {
      return mode == BookReadingMode.simulation ? 'inkReadingKai' : null;
    }
    if (family == BookFontService.systemFamily) return null;
    return family;
  }

  /// 开/关图书独立设置：开 = 用当前全局快照建条目；关 = 删条目（回退全局）。
  Future<void> setIndependentBook(String bookId, bool value) async {
    final exists = _book.containsKey(bookId);
    if (value && !exists) {
      final s = SettingsService();
      _book[bookId] = {
        'mode': s.bookReadingMode.index,
        'fontSize': s.bookFontSize,
        'lineHeight': s.bookLineHeight,
        'hPad': s.bookHorizontalPadding,
        'vPad': s.bookVerticalPadding,
        'fontFamily': s.bookFontFamily,
        'reverseTap': s.reverseTap,
        'doublePage': s.doublePage,
        'showHud': s.showReaderHud,
        'volumeKeyTurn': s.volumeKeyTurn,
      };
      notifyListeners();
      await _persistBook();
    } else if (!value && exists) {
      _book.remove(bookId);
      notifyListeners();
      await _persistBook();
    }
  }

  Future<void> setBookMode(String bookId, BookReadingMode mode) async {
    if (_book.containsKey(bookId)) {
      if (_book[bookId]!['mode'] == mode.index) return;
      _book[bookId]!['mode'] = mode.index;
      notifyListeners();
      await _persistBook();
    } else {
      await SettingsService().setBookReadingMode(mode);
    }
  }

  Future<void> setBookFontSize(String bookId, double value) async {
    if (_book.containsKey(bookId)) {
      if (_book[bookId]!['fontSize'] == value) return;
      _book[bookId]!['fontSize'] = value;
      notifyListeners();
      await _persistBook();
    } else {
      await SettingsService().setBookFontSize(value);
    }
  }

  Future<void> setBookLineHeight(String bookId, double value) async {
    if (_book.containsKey(bookId)) {
      if (_book[bookId]!['lineHeight'] == value) return;
      _book[bookId]!['lineHeight'] = value;
      notifyListeners();
      await _persistBook();
    } else {
      await SettingsService().setBookLineHeight(value);
    }
  }

  Future<void> setBookHorizontalPadding(String bookId, double value) async {
    if (_book.containsKey(bookId)) {
      if (_book[bookId]!['hPad'] == value) return;
      _book[bookId]!['hPad'] = value;
      notifyListeners();
      await _persistBook();
    } else {
      await SettingsService().setBookHorizontalPadding(value);
    }
  }

  Future<void> setBookVerticalPadding(String bookId, double value) async {
    if (_book.containsKey(bookId)) {
      if (_book[bookId]!['vPad'] == value) return;
      _book[bookId]!['vPad'] = value;
      notifyListeners();
      await _persistBook();
    } else {
      await SettingsService().setBookVerticalPadding(value);
    }
  }

  Future<void> setBookFontFamily(String bookId, String? value) async {
    if (_book.containsKey(bookId)) {
      // 空 normalized 比较：'' 与 null 视为同一
      final cur = _book[bookId]!['fontFamily'];
      final curNorm = (cur is String && cur.isEmpty) ? null : cur;
      final newNorm = (value == null || value.isEmpty) ? null : value;
      if (curNorm == newNorm) return;
      _book[bookId]!['fontFamily'] = newNorm;
      notifyListeners();
      await _persistBook();
    } else {
      await SettingsService().setBookFontFamily(value);
    }
  }

  Future<void> setBookReverseTap(String bookId, bool value) async {
    if (_book.containsKey(bookId)) {
      if (_book[bookId]!['reverseTap'] == value) return;
      _book[bookId]!['reverseTap'] = value;
      notifyListeners();
      await _persistBook();
    } else {
      await SettingsService().setReverseTap(value);
    }
  }

  Future<void> setBookDoublePage(String bookId, bool value) async {
    if (_book.containsKey(bookId)) {
      if (_book[bookId]!['doublePage'] == value) return;
      _book[bookId]!['doublePage'] = value;
      notifyListeners();
      await _persistBook();
    } else {
      await SettingsService().setDoublePage(value);
    }
  }

  Future<void> setBookShowHud(String bookId, bool value) async {
    if (_book.containsKey(bookId)) {
      if (_book[bookId]!['showHud'] == value) return;
      _book[bookId]!['showHud'] = value;
      notifyListeners();
      await _persistBook();
    } else {
      await SettingsService().setShowReaderHud(value);
    }
  }

  Future<void> setBookVolumeKeyTurn(String bookId, bool value) async {
    if (_book.containsKey(bookId)) {
      if (_book[bookId]!['volumeKeyTurn'] == value) return;
      _book[bookId]!['volumeKeyTurn'] = value;
      notifyListeners();
      await _persistBook();
    } else {
      await SettingsService().setVolumeKeyTurn(value);
    }
  }
}
