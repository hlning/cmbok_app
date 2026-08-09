import 'dart:ui';
import 'package:flutter/material.dart';

/// 果冻风主题配置
class JellyTheme {
  // 主色调 - 果冻紫蓝渐变
  static const Color primary = Color(0xFF6D73AA);
  static const Color primaryLight = Color(0xFF8E94C6);
  static const Color primaryDark = Color(0xFF4A4F7A);

  // 辅助色
  static const Color accent = Color(0xFFFFB4A2);
  static const Color success = Color(0xFF7FDB9F);
  static const Color warning = Color(0xFFFFD97D);
  static const Color error = Color(0xFFFF8B94);
  static const Color blue = Color(0xFF2196F3); // 蓝色标记（章节正在阅读/已读）

  // 背景色（淡紫色风格）
  static const Color backgroundLight = Color(0xFFEDF3FB);
  static const Color backgroundDark = Color(0xFF1A1A2E);
  static const Color cardLight = Colors.white;
  static const Color cardDark = Color(0xFF252542);

  // 导航栏配色（淡紫色风格）
  static const Color navSelectedBg = Color(0xFFD0CCFF); // 选中背景色
  static const Color navSelectedFg = Color(0xFF443EB1); // 选中图标/文字色
  static const Color navUnselected = Color(0xFF23232C); // 未选中图标色

  // 文字颜色
  static const Color textPrimaryLight = Color(0xFF2D3142);
  static const Color textPrimaryDark = Colors.white;
  static const Color textSecondary = Color(0xFF9CA3AF);

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
          ? const Color(0xFF252542).withValues(alpha: alpha)
          : Colors.white.withValues(alpha: alpha),
      border: Border.all(
        color: isDark
            ? Colors.white.withValues(alpha: borderAlpha)
            : JellyTheme.primary.withValues(alpha: borderAlpha * 2),
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
      colorScheme: const ColorScheme.light(
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
        titleTextStyle: const TextStyle(
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
        hintStyle: const TextStyle(color: textSecondary),
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
      colorScheme: const ColorScheme.dark(
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
        titleTextStyle: const TextStyle(
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
        fillColor: const Color(0xFF2D2D4A),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(16),
          borderSide: BorderSide.none,
        ),
        contentPadding: const EdgeInsets.symmetric(
          horizontal: 20,
          vertical: 16,
        ),
        hintStyle: const TextStyle(color: textSecondary),
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
    Color color = primary,
    double blurRadius = 20,
    double spreadRadius = 0,
  }) {
    return [
      BoxShadow(
        color: color.withValues(alpha: 0.3),
        blurRadius: blurRadius,
        spreadRadius: spreadRadius,
        offset: const Offset(0, 8),
      ),
    ];
  }

  /// 果冻渐变
  static LinearGradient jellyGradient({Color start = primary, Color? end}) {
    return LinearGradient(
      begin: Alignment.topLeft,
      end: Alignment.bottomRight,
      colors: [start, end ?? start.withValues(alpha: 0.7)],
    );
  }
}
