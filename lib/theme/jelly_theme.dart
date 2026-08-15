import 'dart:ui';
import 'package:flutter/material.dart';

import 'jelly_palette.dart';

/// 果冻风主题配置
///
/// 颜色经 [_palette]（[JellyPalette]）驱动：各 `static Color get xxx` 读取当前
/// 调色板，切换主题只需 [apply] 换 _palette 并重建（调用点仍用 `JellyTheme.primary`
/// 等不变）。三套预设见 [JellyPalette.jelly/pink/green]。
class JellyTheme {
  static JellyPalette _palette = const JellyPalette.jelly();

  /// 切换主题调色板（需配合重建生效，见 main.dart 的主题动画接线）
  static void apply(JellyPalette palette) {
    _palette = palette;
  }

  /// 当前调色板（供动画 painter 等按需取色）
  static JellyPalette get palette => _palette;

  // 主色调
  static Color get primary => _palette.primary;
  static Color get primaryLight => _palette.primaryLight;
  static Color get primaryDark => _palette.primaryDark;

  // 辅助色
  static Color get accent => _palette.accent;
  static Color get success => _palette.success;
  static Color get warning => _palette.warning;
  static Color get error => _palette.error;
  static Color get blue => _palette.blue; // 蓝色标记（章节正在阅读/已读）

  // 背景色
  static Color get backgroundLight => _palette.backgroundLight;
  static Color get backgroundDark => _palette.backgroundDark;
  static Color get cardLight => _palette.cardLight;
  static Color get cardDark => _palette.cardDark;

  // 导航栏配色
  static Color get navSelectedBg => _palette.navSelectedBg; // 选中背景色
  static Color get navSelectedFg => _palette.navSelectedFg; // 选中图标/文字色
  static Color get navUnselected => _palette.navUnselected; // 未选中图标色

  // 文字颜色
  static Color get textPrimaryLight => _palette.textPrimaryLight;
  static Color get textPrimaryDark => _palette.textPrimaryDark;
  static Color get textSecondary => _palette.textSecondary;

  /// 毛玻璃效果滤镜
  static final ImageFilter glassFilter = ImageFilter.blur(
    sigmaX: 15,
    sigmaY: 15,
  );

  /// 毛玻璃容器装饰
  static BoxDecoration glassDecoration({
    required bool isDark,
    double alpha = 0.85,
    double borderAlpha = 0.1,
  }) {
    return BoxDecoration(
      color: isDark
          ? cardDark.withValues(alpha: alpha)
          : cardLight.withValues(alpha: alpha),
      border: Border.all(
        color: isDark
            ? Colors.white.withValues(alpha: borderAlpha)
            : primary.withValues(alpha: borderAlpha * 2),
        width: 1,
      ),
    );
  }

  /// 亮色主题
  static ThemeData get light {
    return ThemeData(
      useMaterial3: true,
      brightness: Brightness.light,
      primaryColor: primary,
      scaffoldBackgroundColor: backgroundLight,

      // 颜色方案
      colorScheme: ColorScheme.light(
        primary: primary,
        secondary: accent,
        surface: cardLight,
        error: error,
      ),

      // AppBar 主题
      appBarTheme: AppBarTheme(
        elevation: 0,
        centerTitle: true,
        backgroundColor: backgroundLight,
        foregroundColor: textPrimaryLight,
        titleTextStyle: TextStyle(
          fontSize: 18,
          fontWeight: FontWeight.w600,
          color: textPrimaryLight,
        ),
      ),

      // 卡片主题
      cardTheme: CardThemeData(
        elevation: 8,
        shadowColor: primary.withValues(alpha: 0.15),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        color: cardLight,
      ),

      // 按钮主题
      elevatedButtonTheme: ElevatedButtonThemeData(
        style: ElevatedButton.styleFrom(
          backgroundColor: primary,
          foregroundColor: Colors.white,
          elevation: 5,
          shadowColor: primary.withValues(alpha: 0.4),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
          ),
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 14),
        ),
      ),

      // 输入框主题
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: Colors.grey[100],
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(16),
          borderSide: BorderSide.none,
        ),
        contentPadding: const EdgeInsets.symmetric(
          horizontal: 20,
          vertical: 16,
        ),
        hintStyle: TextStyle(color: textSecondary),
      ),

      // 文字主题
      textTheme: const TextTheme(
        titleLarge: TextStyle(fontSize: 24, fontWeight: FontWeight.bold),
        titleMedium: TextStyle(fontSize: 18, fontWeight: FontWeight.w600),
        bodyLarge: TextStyle(fontSize: 16),
        bodyMedium: TextStyle(fontSize: 14),
      ),
    );
  }

  /// 暗色主题
  static ThemeData get dark {
    return ThemeData(
      useMaterial3: true,
      brightness: Brightness.dark,
      primaryColor: primaryLight,
      scaffoldBackgroundColor: backgroundDark,

      // 颜色方案
      colorScheme: ColorScheme.dark(
        primary: primaryLight,
        secondary: accent,
        surface: cardDark,
        error: error,
      ),

      // AppBar 主题
      appBarTheme: AppBarTheme(
        elevation: 0,
        centerTitle: true,
        backgroundColor: backgroundDark,
        foregroundColor: textPrimaryDark,
        titleTextStyle: TextStyle(
          fontSize: 18,
          fontWeight: FontWeight.w600,
          color: textPrimaryDark,
        ),
      ),

      // 卡片主题
      cardTheme: CardThemeData(
        elevation: 8,
        shadowColor: Colors.black.withValues(alpha: 0.3),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        color: cardDark,
      ),

      // 按钮主题
      elevatedButtonTheme: ElevatedButtonThemeData(
        style: ElevatedButton.styleFrom(
          backgroundColor: primaryLight,
          foregroundColor: Colors.white,
          elevation: 5,
          shadowColor: primaryLight.withValues(alpha: 0.4),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
          ),
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 14),
        ),
      ),

      // 输入框主题
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: cardDark,
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(16),
          borderSide: BorderSide.none,
        ),
        contentPadding: const EdgeInsets.symmetric(
          horizontal: 20,
          vertical: 16,
        ),
        hintStyle: TextStyle(color: textSecondary),
      ),

      // 文字主题
      textTheme: const TextTheme(
        titleLarge: TextStyle(fontSize: 24, fontWeight: FontWeight.bold),
        titleMedium: TextStyle(fontSize: 18, fontWeight: FontWeight.w600),
        bodyLarge: TextStyle(fontSize: 16, color: Colors.white),
        bodyMedium: TextStyle(fontSize: 14, color: Colors.white70),
      ),
    );
  }

  /// 果冻阴影效果
  static List<BoxShadow> jellyShadows({
    Color? color,
    double blurRadius = 20,
    double spreadRadius = 0,
  }) {
    final c = color ?? primary;
    return [
      BoxShadow(
        color: c.withValues(alpha: 0.3),
        blurRadius: blurRadius,
        spreadRadius: spreadRadius,
        offset: const Offset(0, 8),
      ),
    ];
  }

  /// 果冻渐变
  static LinearGradient jellyGradient({Color? start, Color? end}) {
    final s = start ?? primary;
    return LinearGradient(
      begin: Alignment.topLeft,
      end: Alignment.bottomRight,
      colors: [s, end ?? s.withValues(alpha: 0.7)],
    );
  }
}
