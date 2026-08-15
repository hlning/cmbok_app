import 'package:flutter/material.dart';

/// 主题调色板：持有一套主题的全部颜色（含 light + dark 两套色）。
///
/// 不可变（const 构造），新增主题只加一个命名构造；未来「用户自定义」可基于
/// 某预设 copyWith 覆盖个别字段，无需改架构。颜色经 [JellyTheme] 的同名 getter
/// 暴露给全项目（`JellyTheme.primary` -> `_palette.primary`），切换主题即换 _palette。
class JellyPalette {
  const JellyPalette({
    required this.primary,
    required this.primaryLight,
    required this.primaryDark,
    required this.accent,
    required this.success,
    required this.warning,
    required this.error,
    required this.blue,
    required this.backgroundLight,
    required this.backgroundDark,
    required this.cardLight,
    required this.cardDark,
    required this.navSelectedBg,
    required this.navSelectedFg,
    required this.navUnselected,
    required this.textPrimaryLight,
    required this.textPrimaryDark,
    required this.textSecondary,
  });

  /// 果冻紫蓝（默认，搬自原 JellyTheme 常量）
  const JellyPalette.jelly()
    : primary = const Color(0xFF6D73AA),
      primaryLight = const Color(0xFF8E94C6),
      primaryDark = const Color(0xFF4A4F7A),
      accent = const Color(0xFFFFB4A2),
      success = const Color(0xFF7FDB9F),
      warning = const Color(0xFFFFD97D),
      error = const Color(0xFFFF8B94),
      blue = const Color(0xFF2196F3),
      backgroundLight = const Color(0xFFEDF3FB),
      backgroundDark = const Color(0xFF1A1A2E),
      cardLight = Colors.white,
      cardDark = const Color(0xFF252542),
      navSelectedBg = const Color(0xFFD0CCFF),
      navSelectedFg = const Color(0xFF443EB1),
      navUnselected = const Color(0xFF23232C),
      textPrimaryLight = const Color(0xFF2D3142),
      textPrimaryDark = Colors.white,
      textSecondary = const Color(0xFF9CA3AF);

  /// 粉色可爱少女风：灰玫瑰粉低饱和主色 + 柔粉米白背景，配柔淡紫强调；
  /// dark 取深褐底，文字用带粉调 off-white 降低对比眩光。
  const JellyPalette.pink()
    : primary = const Color(0xFFCB8A9E),
      primaryLight = const Color(0xFFDFA9B8),
      primaryDark = const Color(0xFFA06378),
      accent = const Color(0xFFB89EC9),
      success = const Color(0xFF7FDB9F),
      warning = const Color(0xFFFFD97D),
      error = const Color(0xFFFF6B81),
      blue = const Color(0xFF2196F3),
      backgroundLight = const Color(0xFFF8F2F4),
      backgroundDark = const Color(0xFF251E23),
      cardLight = Colors.white,
      cardDark = const Color(0xFF332A2F),
      navSelectedBg = const Color(0xFFE6CBD3),
      navSelectedFg = const Color(0xFFA66077),
      navUnselected = const Color(0xFF2D2329),
      textPrimaryLight = const Color(0xFF3D2B32),
      textPrimaryDark = const Color(0xFFF2E8EA),
      textSecondary = const Color(0xFFA0929A);

  /// 淡绿清新自然风：鼠尾草绿低饱和主色 + 浅绿米白背景，配柔米橙强调；
  /// dark 取深林底，文字用带绿调 off-white 降低对比眩光。
  const JellyPalette.green()
    : primary = const Color(0xFF7BA687),
      primaryLight = const Color(0xFFA3C5AF),
      primaryDark = const Color(0xFF547A66),
      accent = const Color(0xFFD4A574),
      success = const Color(0xFF66BB6A),
      warning = const Color(0xFFFFD97D),
      error = const Color(0xFFEF5350),
      blue = const Color(0xFF2196F3),
      backgroundLight = const Color(0xFFF3F6EF),
      backgroundDark = const Color(0xFF1E2620),
      cardLight = Colors.white,
      cardDark = const Color(0xFF283029),
      navSelectedBg = const Color(0xFFCFE0CE),
      navSelectedFg = const Color(0xFF3D6B45),
      navUnselected = const Color(0xFF232A25),
      textPrimaryLight = const Color(0xFF2A3B2F),
      textPrimaryDark = const Color(0xFFEAF0EA),
      textSecondary = const Color(0xFF8E9C90);

  /// 蓝色海洋风：灰青蓝低饱和主色 + 浅蓝灰背景，配暖沙强调；
  /// dark 取深海底，文字用带蓝调 off-white 降低对比眩光。
  const JellyPalette.ocean()
    : primary = const Color(0xFF4A8AA0),
      primaryLight = const Color(0xFF7AAFC2),
      primaryDark = const Color(0xFF355F73),
      accent = const Color(0xFFD4A574),
      success = const Color(0xFF66BB6A),
      warning = const Color(0xFFFFD97D),
      error = const Color(0xFFEF5350),
      blue = const Color(0xFF2196F3),
      backgroundLight = const Color(0xFFEFF4F8),
      backgroundDark = const Color(0xFF1A2228),
      cardLight = Colors.white,
      cardDark = const Color(0xFF243038),
      navSelectedBg = const Color(0xFFCADCE6),
      navSelectedFg = const Color(0xFF355F73),
      navUnselected = const Color(0xFF232A2E),
      textPrimaryLight = const Color(0xFF2A333A),
      textPrimaryDark = const Color(0xFFEAF0F2),
      textSecondary = const Color(0xFF8A9CA6);

  /// 落日余晖风：赤陶橙低饱和主色 + 暖米白背景，配晚霞紫粉强调；
  /// dark 取深暖褐底，文字用带暖调 off-white 降低对比眩光。
  const JellyPalette.sunset()
    : primary = const Color(0xFFC17A5A),
      primaryLight = const Color(0xFFDAA582),
      primaryDark = const Color(0xFF9A5A3E),
      accent = const Color(0xFFB088A6),
      success = const Color(0xFF66BB6A),
      warning = const Color(0xFFFFD97D),
      error = const Color(0xFFEF5350),
      blue = const Color(0xFF2196F3),
      backgroundLight = const Color(0xFFFBF4EE),
      backgroundDark = const Color(0xFF26201E),
      cardLight = Colors.white,
      cardDark = const Color(0xFF332B27),
      navSelectedBg = const Color(0xFFE8CFBC),
      navSelectedFg = const Color(0xFF9A5A3E),
      navUnselected = const Color(0xFF2A2422),
      textPrimaryLight = const Color(0xFF3A2E28),
      textPrimaryDark = const Color(0xFFF2EAE4),
      textSecondary = const Color(0xFF9C8A82);

  /// 蓝色天空风：明亮天蓝低饱和主色 + 清新浅蓝背景，配日光黄强调；
  /// dark 取深夜空底，文字用带蓝调 off-white 降低对比眩光。
  const JellyPalette.sky()
    : primary = const Color(0xFF6BA6CC),
      primaryLight = const Color(0xFFA0CDE3),
      primaryDark = const Color(0xFF4A7C9E),
      accent = const Color(0xFFE6C267),
      success = const Color(0xFF66BB6A),
      warning = const Color(0xFFFFD97D),
      error = const Color(0xFFEF5350),
      blue = const Color(0xFF2196F3),
      backgroundLight = const Color(0xFFEFF6FB),
      backgroundDark = const Color(0xFF1A2229),
      cardLight = Colors.white,
      cardDark = const Color(0xFF243039),
      navSelectedBg = const Color(0xFFCFE3F0),
      navSelectedFg = const Color(0xFF4A7C9E),
      navUnselected = const Color(0xFF232A30),
      textPrimaryLight = const Color(0xFF2A333D),
      textPrimaryDark = const Color(0xFFEAF1F5),
      textSecondary = const Color(0xFF8A9CA8);

  final Color primary;
  final Color primaryLight;
  final Color primaryDark;
  final Color accent;
  final Color success;
  final Color warning;
  final Color error;
  final Color blue;
  final Color backgroundLight;
  final Color backgroundDark;
  final Color cardLight;
  final Color cardDark;
  final Color navSelectedBg;
  final Color navSelectedFg;
  final Color navUnselected;
  final Color textPrimaryLight;
  final Color textPrimaryDark;
  final Color textSecondary;

  /// 逐色覆盖，返回新调色板（编辑器用）。未传的字段保留原值。
  JellyPalette copyWith({
    Color? primary,
    Color? primaryLight,
    Color? primaryDark,
    Color? accent,
    Color? success,
    Color? warning,
    Color? error,
    Color? blue,
    Color? backgroundLight,
    Color? backgroundDark,
    Color? cardLight,
    Color? cardDark,
    Color? navSelectedBg,
    Color? navSelectedFg,
    Color? navUnselected,
    Color? textPrimaryLight,
    Color? textPrimaryDark,
    Color? textSecondary,
  }) {
    return JellyPalette(
      primary: primary ?? this.primary,
      primaryLight: primaryLight ?? this.primaryLight,
      primaryDark: primaryDark ?? this.primaryDark,
      accent: accent ?? this.accent,
      success: success ?? this.success,
      warning: warning ?? this.warning,
      error: error ?? this.error,
      blue: blue ?? this.blue,
      backgroundLight: backgroundLight ?? this.backgroundLight,
      backgroundDark: backgroundDark ?? this.backgroundDark,
      cardLight: cardLight ?? this.cardLight,
      cardDark: cardDark ?? this.cardDark,
      navSelectedBg: navSelectedBg ?? this.navSelectedBg,
      navSelectedFg: navSelectedFg ?? this.navSelectedFg,
      navUnselected: navUnselected ?? this.navUnselected,
      textPrimaryLight: textPrimaryLight ?? this.textPrimaryLight,
      textPrimaryDark: textPrimaryDark ?? this.textPrimaryDark,
      textSecondary: textSecondary ?? this.textSecondary,
    );
  }

  /// 序列化为 `{字段名: #AARRGGBB}`，用于自定义主题持久化。
  Map<String, String> toMap() => {
    'primary': _toHex(primary),
    'primaryLight': _toHex(primaryLight),
    'primaryDark': _toHex(primaryDark),
    'accent': _toHex(accent),
    'success': _toHex(success),
    'warning': _toHex(warning),
    'error': _toHex(error),
    'blue': _toHex(blue),
    'backgroundLight': _toHex(backgroundLight),
    'backgroundDark': _toHex(backgroundDark),
    'cardLight': _toHex(cardLight),
    'cardDark': _toHex(cardDark),
    'navSelectedBg': _toHex(navSelectedBg),
    'navSelectedFg': _toHex(navSelectedFg),
    'navUnselected': _toHex(navUnselected),
    'textPrimaryLight': _toHex(textPrimaryLight),
    'textPrimaryDark': _toHex(textPrimaryDark),
    'textSecondary': _toHex(textSecondary),
  };

  /// 由 `{字段名: hex}` 重建调色板；单字段缺失/非法时回退 jelly 对应色（韧性解析）。
  factory JellyPalette.fromMap(Map<String, dynamic> map) {
    const j = JellyPalette.jelly();
    return JellyPalette(
      primary: _fromHex(map['primary'], j.primary),
      primaryLight: _fromHex(map['primaryLight'], j.primaryLight),
      primaryDark: _fromHex(map['primaryDark'], j.primaryDark),
      accent: _fromHex(map['accent'], j.accent),
      success: _fromHex(map['success'], j.success),
      warning: _fromHex(map['warning'], j.warning),
      error: _fromHex(map['error'], j.error),
      blue: _fromHex(map['blue'], j.blue),
      backgroundLight: _fromHex(map['backgroundLight'], j.backgroundLight),
      backgroundDark: _fromHex(map['backgroundDark'], j.backgroundDark),
      cardLight: _fromHex(map['cardLight'], j.cardLight),
      cardDark: _fromHex(map['cardDark'], j.cardDark),
      navSelectedBg: _fromHex(map['navSelectedBg'], j.navSelectedBg),
      navSelectedFg: _fromHex(map['navSelectedFg'], j.navSelectedFg),
      navUnselected: _fromHex(map['navUnselected'], j.navUnselected),
      textPrimaryLight: _fromHex(map['textPrimaryLight'], j.textPrimaryLight),
      textPrimaryDark: _fromHex(map['textPrimaryDark'], j.textPrimaryDark),
      textSecondary: _fromHex(map['textSecondary'], j.textSecondary),
    );
  }

  static String _toHex(Color c) =>
      '#${c.toARGB32().toRadixString(16).padLeft(8, '0').toUpperCase()}';

  static Color _fromHex(Object? v, Color fallback) {
    if (v is String && v.isNotEmpty) {
      var s = v.trim();
      if (s.startsWith('#')) s = s.substring(1);
      // 兼容 RRGGBB（补 FF alpha）与 AARRGGBB
      if (s.length == 6) s = 'FF$s';
      final parsed = int.tryParse(s, radix: 16);
      if (parsed != null) return Color(parsed);
    }
    return fallback;
  }

  /// 按 preset id 取调色板（仅内置预设；未知 id 兜底回 jelly）。
  /// 自定义主题的解析见 [SettingsService._resolvePalette]。
  factory JellyPalette.fromPreset(String id) {
    switch (id) {
      case 'pink':
        return const JellyPalette.pink();
      case 'green':
        return const JellyPalette.green();
      case 'ocean':
        return const JellyPalette.ocean();
      case 'sunset':
        return const JellyPalette.sunset();
      case 'sky':
        return const JellyPalette.sky();
      default:
        return const JellyPalette.jelly();
    }
  }
}

/// 自定义主题背景类型（三选一，互斥）。
enum ThemeBackgroundType { none, animation, image }

/// 自定义主题的背景配置（仅对自定义主题生效；内置 6 套主题恒用各自专属动画，
/// 不读此字段）。
///
/// - [ThemeBackgroundType.none]：纯色，透出 Scaffold 底色（=旧自定义主题行为）。
/// - [ThemeBackgroundType.animation]：借用某套内置背景动画（[animationId] 取
///   green/jelly/pink/ocean/sunset/sky），元素颜色随本主题调色板。
/// - [ThemeBackgroundType.image]：用户上传图片（[imagePath] 为复制到 app 目录后的
///   绝对路径）。
class ThemeBackground {
  const ThemeBackground({
    this.type = ThemeBackgroundType.none,
    this.animationId,
    this.imagePath,
  });

  const ThemeBackground.none()
    : type = ThemeBackgroundType.none,
      animationId = null,
      imagePath = null;

  const ThemeBackground.animation(String id)
    : type = ThemeBackgroundType.animation,
      animationId = id,
      imagePath = null;

  const ThemeBackground.image(String path)
    : type = ThemeBackgroundType.image,
      animationId = null,
      imagePath = path;

  final ThemeBackgroundType type;
  final String? animationId;
  final String? imagePath;

  /// 序列化；缺省字段省略。旧自定义主题无 `background` 节点时由
  /// [fromMap] 回退 [ThemeBackground.none]（向后兼容）。
  Map<String, dynamic> toMap() {
    final m = <String, dynamic>{'type': type.name};
    if (animationId != null) m['animationId'] = animationId;
    if (imagePath != null) m['imagePath'] = imagePath;
    return m;
  }

  /// 由 map 重建；type 缺失/非法或对应字段缺失 → none（韧性解析）。
  factory ThemeBackground.fromMap(Object? raw) {
    if (raw is! Map) return const ThemeBackground.none();
    final t = raw['type'];
    ThemeBackgroundType? type;
    if (t is String) {
      for (final v in ThemeBackgroundType.values) {
        if (v.name == t) {
          type = v;
          break;
        }
      }
    }
    switch (type) {
      case ThemeBackgroundType.animation:
        final id = raw['animationId'];
        return id is String
            ? ThemeBackground.animation(id)
            : const ThemeBackground.none();
      case ThemeBackgroundType.image:
        final p = raw['imagePath'];
        return p is String
            ? ThemeBackground.image(p)
            : const ThemeBackground.none();
      default:
        return const ThemeBackground.none();
    }
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is ThemeBackground &&
          other.type == type &&
          other.animationId == animationId &&
          other.imagePath == imagePath);

  @override
  int get hashCode => Object.hash(type, animationId, imagePath);
}

/// 主题预设元信息（UI 展示用：id + 名称 + 调色板取色块）
class ThemePresetInfo {
  const ThemePresetInfo(
    this.id,
    this.name,
    this.palette, {
    this.background = const ThemeBackground(),
  });

  final String id;
  final String name;
  final JellyPalette palette;

  /// 背景配置（仅自定义主题用；内置预设恒用各自动画，此字段被忽略）。
  final ThemeBackground background;
}

/// 全部主题预设（顺序即展示顺序）
const List<ThemePresetInfo> themePresets = [
  ThemePresetInfo('jelly', '魅力紫色', JellyPalette.jelly()),
  ThemePresetInfo('pink', '粉色少女', JellyPalette.pink()),
  ThemePresetInfo('green', '清新护眼', JellyPalette.green()),
  ThemePresetInfo('ocean', '蓝色海洋', JellyPalette.ocean()),
  ThemePresetInfo('sunset', '落日余晖', JellyPalette.sunset()),
  ThemePresetInfo('sky', '蓝色天空', JellyPalette.sky()),
];
