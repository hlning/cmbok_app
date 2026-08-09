import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'pages/home_page.dart';
import 'services/book_download_service.dart';
import 'services/book_favorites_service.dart';
import 'services/peer_transfer_service.dart';
import 'services/bookshelf_service.dart';
import 'services/book_reading_progress_service.dart';
import 'services/book_view_mode.dart';
import 'services/download_service.dart';
import 'services/favorites_service.dart';
import 'services/reading_progress_service.dart';
import 'services/remote_config_service.dart';
import 'services/settings_service.dart';
import 'services/theme_switch.dart';
import 'services/view_mode.dart';
import 'services/zlibrary_service.dart';
import 'theme/jelly_theme.dart';
import 'utils/constants.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await RemoteConfigService().init();
  await SettingsService().init();
  await ViewMode().init();
  await BookViewMode().init();
  await FavoritesService().init();
  await BookFavoritesService().init();
  await BookshelfService().init();
  await DownloadService().init();
  await ReadingProgressService().init();
  await BookReadingProgressService().init();
  await ZlibraryService().init();
  await BookDownloadService().init();
  await PeerTransferService().init();
  runApp(const MyApp());
}

class MyApp extends StatefulWidget {
  const MyApp({super.key});

  @override
  State<MyApp> createState() => _MyAppState();
}

class _MyAppState extends State<MyApp> with SingleTickerProviderStateMixin {
  final _boundaryKey = GlobalKey();
  bool _animating = false;
  bool _lastDarkMode = false;
  late final AnimationController _revealController;
  ui.Image? _snapshot;
  Offset? _origin; // 圆形扩散动画起点（图标中心）
  double _maxRadius = 0; // 圆形扩散最大半径（起点到屏幕四角最远距离）

  @override
  void initState() {
    super.initState();
    _lastDarkMode = SettingsService().isDarkMode;
    _revealController =
        AnimationController(
          vsync: this,
          duration: const Duration(milliseconds: 450),
        )..addStatusListener((status) {
          if (status == AnimationStatus.completed && mounted) {
            setState(() {
              _animating = false;
              _origin = null;
              _snapshot?.dispose();
              _snapshot = null;
            });
          }
        });
    SettingsService().addListener(_onSettingsChanged);
  }

  @override
  void dispose() {
    SettingsService().removeListener(_onSettingsChanged);
    _revealController.dispose();
    _snapshot?.dispose();
    super.dispose();
  }

  /// 仅在暗色模式变化时触发过渡动画；其它设置变化不重建（各自控件自行监听）
  void _onSettingsChanged() {
    if (!mounted || _animating) return;
    final dark = SettingsService().isDarkMode;
    if (_lastDarkMode == dark) return;
    _lastDarkMode = dark;
    _animateThemeSwitch();
  }

  /// 截取当前画面，切换主题后以图标中心为起点圆形扩散揭示新主题
  Future<void> _animateThemeSwitch() async {
    final ctx = _boundaryKey.currentContext;
    final boundary = ctx?.findRenderObject() as RenderRepaintBoundary?;
    if (boundary == null || ctx == null) {
      if (mounted) setState(() {});
      return;
    }
    _animating = true;
    // 屏幕尺寸需在异步间隙前获取（避免在 await 后使用 BuildContext）
    final size = MediaQuery.of(ctx).size;
    ui.Image? image;
    try {
      final ratio = MediaQuery.of(ctx).devicePixelRatio;
      image = await boundary.toImage(pixelRatio: ratio);
    } catch (_) {
      image = null;
    }
    if (!mounted) {
      _animating = false;
      return;
    }
    if (image == null) {
      _animating = false;
      setState(() {});
      return;
    }
    _snapshot?.dispose();
    _snapshot = image;
    // 圆形扩散起点：图标中心（由切换按钮写入），缺省屏幕中心
    final origin =
        ThemeSwitch.origin ?? Offset(size.width / 2, size.height / 2);
    ThemeSwitch.origin = null; // 消费即清空
    _origin = origin;
    _maxRadius = [
      Offset.zero,
      Offset(size.width, 0),
      Offset(0, size.height),
      Offset(size.width, size.height),
    ].map((c) => (c - origin).distance).reduce((a, b) => a > b ? a : b);
    setState(() {}); // 切换到新主题 + 叠加旧截图（圆形挖孔扩散）
    _revealController.forward(from: 0);
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: AppConstants.appName,
      theme: JellyTheme.light,
      darkTheme: JellyTheme.dark,
      themeMode: SettingsService().isDarkMode
          ? ThemeMode.dark
          : ThemeMode.light,
      home: Stack(
        fit: StackFit.expand,
        children: [
          RepaintBoundary(key: _boundaryKey, child: const HomePage()),
          if (_animating && _snapshot != null && _origin != null)
            Positioned.fill(
              child: IgnorePointer(
                child: AnimatedBuilder(
                  animation: _revealController,
                  builder: (context, _) {
                    final t = Curves.easeInOutCubic.transform(
                      _revealController.value,
                    );
                    return ClipPath(
                      clipper: _CircleRevealClipper(_origin!, t * _maxRadius),
                      child: RawImage(image: _snapshot!, fit: BoxFit.fill),
                    );
                  },
                ),
              ),
            ),
        ],
      ),
      debugShowCheckedModeBanner: false,
    );
  }
}

/// 圆形扩散裁剪：保留整屏减去一个以 [center] 为圆心、半径 [radius] 的圆，
/// 使该圆形区域内露出下层新主题。半径随动画从 0 扩到 maxRadius，
/// 新主题即从图标处向外扩散揭示。
class _CircleRevealClipper extends CustomClipper<Path> {
  _CircleRevealClipper(this.center, this.radius);

  final Offset center;
  final double radius;

  @override
  Path getClip(Size size) {
    return Path.combine(
      PathOperation.difference,
      Path()..addRect(Offset.zero & size),
      Path()..addOval(Rect.fromCircle(center: center, radius: radius)),
    );
  }

  @override
  bool shouldReclip(_CircleRevealClipper old) =>
      center != old.center || radius != old.radius;
}
