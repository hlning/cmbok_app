import 'package:flutter/material.dart';
import '../services/settings_service.dart';
import '../theme/jelly_theme.dart';

/// 漫画阅读模式下拉选项顺序（与枚举顺序解耦：枚举末尾为 dissolve/leftToRight/none
/// 以保持旧持久化 index 不变；这里展示为 从右往左/从左往右/消散/拼页/无动画）
const _mangaModes = <ReadingMode>[
  ReadingMode.pageTurn,
  ReadingMode.leftToRight,
  ReadingMode.dissolve,
  ReadingMode.continuous,
  ReadingMode.none,
];

/// 漫画阅读模式下拉文案
const _mangaModeLabels = <ReadingMode, String>{
  ReadingMode.pageTurn: '从右往左',
  ReadingMode.leftToRight: '从左往右',
  ReadingMode.dissolve: '消散',
  ReadingMode.continuous: '拼页',
  ReadingMode.none: '无动画',
};

/// 图书阅读模式下拉选项顺序（枚举末尾为 vertical/none 以保持旧持久化
/// index 不变；这里展示为 左右/上下/仿真/覆盖/无动画）
const _bookModes = <BookReadingMode>[
  BookReadingMode.pageTurn,
  BookReadingMode.vertical,
  BookReadingMode.simulation,
  BookReadingMode.cover,
  BookReadingMode.none,
];

/// 图书阅读模式下拉文案
const _bookModeLabels = <BookReadingMode, String>{
  BookReadingMode.pageTurn: '左右',
  BookReadingMode.vertical: '上下',
  BookReadingMode.simulation: '仿真',
  BookReadingMode.cover: '覆盖',
  BookReadingMode.none: '无动画',
};

/// 阅读设置页：漫画阅读模式（左右翻页 / 上下翻页 / 拼页）
class ReadingSettingsPage extends StatefulWidget {
  const ReadingSettingsPage({super.key});

  @override
  State<ReadingSettingsPage> createState() => _ReadingSettingsPageState();
}

class _ReadingSettingsPageState extends State<ReadingSettingsPage> {
  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Scaffold(
      appBar: AppBar(title: const Text('阅读设置')),
      body: ListenableBuilder(
        listenable: SettingsService(),
        builder: (context, _) {
          final s = SettingsService();
          return ListView(
            padding: const EdgeInsets.all(16),
            children: [
              _buildBookReadingModeCard(isDark, s),
              const SizedBox(height: 12),
              _buildMangaModeCard(isDark, s),
              const SizedBox(height: 12),
              _buildInkScreenCard(isDark, s),
              const SizedBox(height: 12),
              _buildPreloadCard(isDark, s),
              const SizedBox(height: 12),
              _buildReverseTapCard(isDark, s),
              const SizedBox(height: 12),
              _buildDoublePageCard(isDark, s),
              const SizedBox(height: 12),
              _buildShowHudCard(isDark, s),
              const SizedBox(height: 12),
              _buildVolumeKeyCard(isDark, s),
            ],
          );
        },
      ),
    );
  }

  /// 墨水屏模式开关卡片（黑白柔和显示，缓解纯白刺眼）
  Widget _buildInkScreenCard(bool isDark, SettingsService s) {
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 10, 16, 10),
      decoration: BoxDecoration(
        color: isDark ? JellyTheme.cardDark : JellyTheme.cardLight,
        borderRadius: BorderRadius.circular(16),
      ),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  '漫画墨水屏模式',
                  style: TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.bold,
                    color: isDark ? Colors.white : JellyTheme.textPrimaryLight,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  '黑白柔和显示，缓解纯白刺眼',
                  style: TextStyle(
                    fontSize: 12,
                    color: JellyTheme.textSecondary,
                  ),
                ),
              ],
            ),
          ),
          Switch(
            value: s.inkScreenMode,
            activeColor: JellyTheme.primary,
            onChanged: (v) => s.setInkScreenMode(v),
          ),
        ],
      ),
    );
  }

  Widget _buildMangaModeCard(bool isDark, SettingsService s) {
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 14, 8, 14),
      decoration: BoxDecoration(
        color: isDark ? JellyTheme.cardDark : JellyTheme.cardLight,
        borderRadius: BorderRadius.circular(16),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  '漫画阅读模式',
                  style: TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.bold,
                    color: isDark ? Colors.white : JellyTheme.textPrimaryLight,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  '从右往左：图片从右翻入（日漫方向）\n从左往右：图片从左翻入\n消散：当前页淡出、下一页淡入\n拼页：上下连续滚动\n无动画：点击直接切换，不滑动',
                  style: TextStyle(
                    fontSize: 12,
                    color: JellyTheme.textSecondary,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          DropdownButton<ReadingMode>(
            value: s.readingMode,
            underline: const SizedBox(),
            isDense: true,
            style: TextStyle(
              fontSize: 14,
              fontWeight: FontWeight.w600,
              color: isDark ? Colors.white : JellyTheme.textPrimaryLight,
            ),
            dropdownColor: isDark ? JellyTheme.cardDark : Colors.white,
            items: _mangaModes
                .map(
                  (m) => DropdownMenuItem(
                    value: m,
                    child: Text(_mangaModeLabels[m]!),
                  ),
                )
                .toList(),
            onChanged: (v) {
              if (v != null) s.setReadingMode(v);
            },
          ),
        ],
      ),
    );
  }

  /// 图书阅读模式卡片：左右 / 上下 / 仿真 / 覆盖 / 无动画（下拉，同漫画模式）
  Widget _buildBookReadingModeCard(bool isDark, SettingsService s) {
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 14, 8, 14),
      decoration: BoxDecoration(
        color: isDark ? JellyTheme.cardDark : JellyTheme.cardLight,
        borderRadius: BorderRadius.circular(16),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  '图书阅读模式',
                  style: TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.bold,
                    color: isDark ? Colors.white : JellyTheme.textPrimaryLight,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  '左右：左右平移翻页\n上下：上下平移翻页\n仿真：纸张卷曲翻页\n覆盖：新页滑入覆盖当前页\n无动画：点击直接切换，不滑动',
                  style: TextStyle(
                    fontSize: 12,
                    color: JellyTheme.textSecondary,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          DropdownButton<BookReadingMode>(
            value: s.bookReadingMode,
            underline: const SizedBox(),
            isDense: true,
            style: TextStyle(
              fontSize: 14,
              fontWeight: FontWeight.w600,
              color: isDark ? Colors.white : JellyTheme.textPrimaryLight,
            ),
            dropdownColor: isDark ? JellyTheme.cardDark : Colors.white,
            items: _bookModes
                .map(
                  (m) => DropdownMenuItem(
                    value: m,
                    child: Text(_bookModeLabels[m]!),
                  ),
                )
                .toList(),
            onChanged: (v) {
              if (v != null) s.setBookReadingMode(v);
            },
          ),
        ],
      ),
    );
  }

  /// 在线预加载图片数卡片：滑块选择 2~10（仿下载设置页滑块卡片样式）
  Widget _buildPreloadCard(bool isDark, SettingsService s) {
    final value = s.preloadImageCount;
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
      decoration: BoxDecoration(
        color: isDark ? JellyTheme.cardDark : JellyTheme.cardLight,
        borderRadius: BorderRadius.circular(16),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text(
                '在线预加载图片',
                style: TextStyle(
                  fontSize: 15,
                  fontWeight: FontWeight.bold,
                  color: isDark ? Colors.white : JellyTheme.textPrimaryLight,
                ),
              ),
              const Spacer(),
              Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 10,
                  vertical: 2,
                ),
                decoration: BoxDecoration(
                  color: JellyTheme.primary.withValues(alpha: 0.15),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Text(
                  '$value',
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.bold,
                    color: JellyTheme.primary,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            '在线阅读时预先加载后续图片，提升翻页流畅度（仅在线阅读生效）',
            style: TextStyle(fontSize: 12, color: JellyTheme.textSecondary),
          ),
          Slider(
            value: value.toDouble(),
            min: SettingsService.minPreloadImages.toDouble(),
            max: SettingsService.maxPreloadImages.toDouble(),
            divisions:
                SettingsService.maxPreloadImages -
                SettingsService.minPreloadImages,
            activeColor: JellyTheme.primary,
            onChanged: (v) => s.setPreloadImageCount(v.round()),
          ),
          Row(
            children: [
              Text(
                '${SettingsService.minPreloadImages}',
                style: TextStyle(fontSize: 11, color: JellyTheme.textSecondary),
              ),
              const Spacer(),
              Text(
                '${SettingsService.maxPreloadImages}',
                style: TextStyle(fontSize: 11, color: JellyTheme.textSecondary),
              ),
            ],
          ),
        ],
      ),
    );
  }

  /// 翻页按钮反转开关卡片（左点下一页、右点上一页）
  Widget _buildReverseTapCard(bool isDark, SettingsService s) {
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 10, 16, 10),
      decoration: BoxDecoration(
        color: isDark ? JellyTheme.cardDark : JellyTheme.cardLight,
        borderRadius: BorderRadius.circular(16),
      ),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  '翻页按钮反转',
                  style: TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.bold,
                    color: isDark ? Colors.white : JellyTheme.textPrimaryLight,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  '开启后：点击左侧下一页、右侧上一页（与默认相反）',
                  style: TextStyle(
                    fontSize: 12,
                    color: JellyTheme.textSecondary,
                  ),
                ),
              ],
            ),
          ),
          Switch(
            value: s.reverseTap,
            activeColor: JellyTheme.primary,
            onChanged: (v) => s.setReverseTap(v),
          ),
        ],
      ),
    );
  }

  /// 双页模式开关卡片（横屏左右并排两页，仅翻页模式生效）
  Widget _buildDoublePageCard(bool isDark, SettingsService s) {
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 10, 16, 10),
      decoration: BoxDecoration(
        color: isDark ? JellyTheme.cardDark : JellyTheme.cardLight,
        borderRadius: BorderRadius.circular(16),
      ),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  '双页模式',
                  style: TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.bold,
                    color: isDark ? Colors.white : JellyTheme.textPrimaryLight,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  '横屏时左右并排显示两页',
                  style: TextStyle(
                    fontSize: 12,
                    color: JellyTheme.textSecondary,
                  ),
                ),
              ],
            ),
          ),
          Switch(
            value: s.doublePage,
            activeColor: JellyTheme.primary,
            onChanged: (v) => s.setDoublePage(v),
          ),
        ],
      ),
    );
  }

  /// 阅读信息栏开关卡片（阅读时角落显示时间、页码、进度等）
  Widget _buildShowHudCard(bool isDark, SettingsService s) {
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 10, 16, 10),
      decoration: BoxDecoration(
        color: isDark ? JellyTheme.cardDark : JellyTheme.cardLight,
        borderRadius: BorderRadius.circular(16),
      ),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  '显示阅读信息',
                  style: TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.bold,
                    color: isDark ? Colors.white : JellyTheme.textPrimaryLight,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  '阅读时在角落显示时间、页码、进度等',
                  style: TextStyle(
                    fontSize: 12,
                    color: JellyTheme.textSecondary,
                  ),
                ),
              ],
            ),
          ),
          Switch(
            value: s.showReaderHud,
            activeColor: JellyTheme.primary,
            onChanged: (v) => s.setShowReaderHud(v),
          ),
        ],
      ),
    );
  }

  /// 音量键翻页开关卡片（阅读时按音量上/下键翻页，会接管音量键）
  Widget _buildVolumeKeyCard(bool isDark, SettingsService s) {
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 10, 16, 10),
      decoration: BoxDecoration(
        color: isDark ? JellyTheme.cardDark : JellyTheme.cardLight,
        borderRadius: BorderRadius.circular(16),
      ),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  '音量键翻页',
                  style: TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.bold,
                    color: isDark ? Colors.white : JellyTheme.textPrimaryLight,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  '阅读时按音量上/下键翻页（会接管音量键）',
                  style: TextStyle(
                    fontSize: 12,
                    color: JellyTheme.textSecondary,
                  ),
                ),
              ],
            ),
          ),
          Switch(
            value: s.volumeKeyTurn,
            activeColor: JellyTheme.primary,
            onChanged: (v) => s.setVolumeKeyTurn(v),
          ),
        ],
      ),
    );
  }
}
