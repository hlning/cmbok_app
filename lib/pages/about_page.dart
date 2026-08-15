import 'package:flutter/material.dart';
import '../theme/jelly_theme.dart';
import '../utils/constants.dart';

/// 关于页面：顶部应用图标+名称+版本，下方免责声明
/// （GitHub / QQ群 在「我的」页底部快捷区）
class AboutPage extends StatelessWidget {
  const AboutPage({super.key});

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final titleColor = isDark ? Colors.white : JellyTheme.textPrimaryLight;
    return Scaffold(
      appBar: AppBar(title: const Text('关于')),
      body: ListView(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
        children: [
          // 应用图标 + 名称 + 版本
          Center(
            child: Column(
              children: [
                Container(
                  width: 72,
                  height: 72,
                  decoration: BoxDecoration(
                    color: JellyTheme.primary.withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(20),
                  ),
                  clipBehavior: Clip.antiAlias,
                  child: Center(
                    child: Image.asset(
                      'assets/icons/logo.png',
                      width: 72,
                      height: 72,
                      fit: BoxFit.cover,
                      errorBuilder: (_, _, _) => Icon(
                        Icons.auto_stories_rounded,
                        size: 40,
                        color: JellyTheme.primary,
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 12),
                Text(
                  '${AppConstants.appName} V${AppConstants.version}',
                  style: TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.bold,
                    color: titleColor,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 20),
          Text(
            '免责声明',
            style: TextStyle(
              fontSize: 15,
              fontWeight: FontWeight.w700,
              color: titleColor,
            ),
          ),
          const SizedBox(height: 8),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: isDark ? JellyTheme.cardDark : JellyTheme.cardLight,
              borderRadius: BorderRadius.circular(16),
            ),
            child: const Text(
              _kDisclaimer,
              style: TextStyle(fontSize: 13, height: 1.6),
            ),
          ),
        ],
      ),
    );
  }
}

const String _kDisclaimer =
    '本应用（Cmbok）仅供个人学习与技术研究使用，严禁用于任何商业或非法用途。'
    '应用内所有漫画、图书及相关内容均来自第三方，本应用不存储、不上传任何内容，'
    '亦不对其内容合法性、准确性负责。所有版权归原作者或原平台所有。'
    '若发现任何侵权或不合规内容，请联系原作者或原平台处理，或反馈至本应用予以移除。'
    '使用本应用产生的一切后果由使用者自行承担。';
