import 'package:flutter/material.dart';
import '../services/settings_service.dart';
import '../theme/jelly_theme.dart';
import '../widgets/jelly_segmented_toggle.dart';

/// 漫画阅读模式显示顺序（与枚举顺序解耦：枚举末尾为 dissolve 以保持旧
/// 持久化 index 不变；这里把"消散"插在中间，展示为 左右/消散/拼页）
const _mangaModes = <ReadingMode>[
  ReadingMode.pageTurn,
  ReadingMode.dissolve,
  ReadingMode.continuous,
];

/// 阅读设置页：漫画阅读模式（左右翻页 / 上下翻页 / 拼页）
class ReadingSettingsPage extends StatefulWidget {
  const ReadingSettingsPage({super.key});

  @override
  State<ReadingSettingsPage> createState() => _ReadingSettingsPageState();
}

class _ReadingSettingsPageState extends State<ReadingSettingsPage>
    with TickerProviderStateMixin {
  late final TabController _mangaTabCtrl;
  late final TabController _bookTabCtrl;
  bool _mangaAnimating = false; // 防止动画触发 SettingsService 回调导致的循环
  bool _bookAnimating = false;

  @override
  void initState() {
    super.initState();
    final s = SettingsService();
    _mangaTabCtrl = TabController(
      length: _mangaModes.length,
      vsync: this,
      initialIndex: _mangaModes.indexOf(s.readingMode),
    );
    _bookTabCtrl = TabController(
      length: 3,
      vsync: this,
      initialIndex: s.bookReadingMode.index,
    );
  }

  @override
  void dispose() {
    _mangaTabCtrl.dispose();
    _bookTabCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Scaffold(
      appBar: AppBar(title: const Text('阅读设置')),
      body: ListenableBuilder(
        listenable: SettingsService(),
        builder: (context, _) {
          final s = SettingsService();
          // 外部状态变化时同步（比如从其他页面改了设置再回来）
          // 但如果是当前页面正在驱动动画导致的变化，就跳过去避免循环
          final mangaIdx = _mangaModes.indexOf(s.readingMode);
          if (!_mangaAnimating && _mangaTabCtrl.index != mangaIdx) {
            _mangaTabCtrl.animateTo(mangaIdx);
          }
          if (!_bookAnimating &&
              _bookTabCtrl.index != s.bookReadingMode.index) {
            _bookTabCtrl.animateTo(s.bookReadingMode.index);
          }
          return ListView(
            padding: const EdgeInsets.all(16),
            children: [
              _buildMangaModeCard(isDark, s),
              const SizedBox(height: 12),
              _buildBookReadingModeCard(isDark, s),
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
                const Text(
                  '左右翻页：横向逐页\n消散：当前页淡出、下一页淡入\n拼页：上下连续滚动',
                  style: TextStyle(
                    fontSize: 12,
                    color: JellyTheme.textSecondary,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          AnimatedBuilder(
            animation: _mangaTabCtrl.animation!,
            builder: (context, _) => JellySegmentedToggle(
              index: _mangaTabCtrl.animation!.value,
              segments: const [
                JellySegmentData(label: '左右'),
                JellySegmentData(label: '消散'),
                JellySegmentData(label: '拼页'),
              ],
              segmentWidth: 56,
              onChanged: (i) {
                _mangaAnimating = true;
                _mangaTabCtrl.animateTo(i);
                s.setReadingMode(_mangaModes[i]);
                // 动画结束后清除标记（约 300ms）
                Future.delayed(const Duration(milliseconds: 320), () {
                  if (mounted) _mangaAnimating = false;
                });
              },
            ),
          ),
        ],
      ),
    );
  }

  /// 图书阅读模式卡片：翻页 / 仿真 / 覆盖
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
                const Text(
                  '翻页：左右平移翻页\n仿真：纸张卷曲翻页\n覆盖：新页滑入覆盖当前页',
                  style: TextStyle(
                    fontSize: 12,
                    color: JellyTheme.textSecondary,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          AnimatedBuilder(
            animation: _bookTabCtrl.animation!,
            builder: (context, _) => JellySegmentedToggle(
              index: _bookTabCtrl.animation!.value,
              segments: const [
                JellySegmentData(label: '翻页'),
                JellySegmentData(label: '仿真'),
                JellySegmentData(label: '覆盖'),
              ],
              segmentWidth: 56,
              onChanged: (i) {
                _bookAnimating = true;
                _bookTabCtrl.animateTo(i);
                s.setBookReadingMode(BookReadingMode.values[i]);
                Future.delayed(const Duration(milliseconds: 320), () {
                  if (mounted) _bookAnimating = false;
                });
              },
            ),
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
                  style: const TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.bold,
                    color: JellyTheme.primary,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 4),
          const Text(
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
                style: const TextStyle(
                  fontSize: 11,
                  color: JellyTheme.textSecondary,
                ),
              ),
              const Spacer(),
              Text(
                '${SettingsService.maxPreloadImages}',
                style: const TextStyle(
                  fontSize: 11,
                  color: JellyTheme.textSecondary,
                ),
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
                const Text(
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
                const Text(
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
                const Text(
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
                const Text(
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
