import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:photo_view/photo_view.dart';
import 'package:photo_view/photo_view_gallery.dart';
import 'package:scrollable_positioned_list/scrollable_positioned_list.dart';
import '../models/comic.dart';
import '../services/bookshelf_service.dart';
import '../source/adapter.dart';
import '../source/image_cache_manager.dart';
import '../source/source_manager.dart';
import '../source/webview_image_fetcher.dart';
import '../services/download_service.dart';
import '../services/platform_service.dart';
import '../services/reading_progress_service.dart';
import '../services/reader_override_service.dart';
import '../services/settings_service.dart';
import '../theme/jelly_theme.dart';
import '../widgets/pomodoro_button.dart';

/// 漫画阅读页面
class ReaderPage extends StatefulWidget {
  final Comic comic;
  final ComicChapter chapter;
  final List<ChapterGroup> groups;

  /// 续读起始页（从 0 起），由下载页"继续阅读"传入
  final int initialPage;

  const ReaderPage({
    super.key,
    required this.comic,
    required this.chapter,
    required this.groups,
    this.initialPage = 0,
  });

  @override
  State<ReaderPage> createState() => _ReaderPageState();
}

class _ReaderPageState extends State<ReaderPage> {
  late ComicChapter _currentChapter;
  List<String> _images = [];
  bool _isLoading = true;
  String? _error;
  int _currentIndex = 0;

  /// 最近一次归位的书架状态（presetReading/presetFinished），避免频繁移动
  String? _lastAppliedStatus;
  bool _showControls = true;
  bool _useLocal = false; // 是否使用本地已下载图片

  /// 在线图片请求头（防盗链/UA，随当前源 imageHeaders+referer）
  Map<String, String> _imageHeaders = const {};

  /// 翻页模式控制器（程序化翻页用）
  late PageController _pageController;

  /// 拼页模式：按索引滚动/跳转
  final ItemScrollController _itemScrollController = ItemScrollController();

  /// 拼页模式：像素级平滑滚动（绕开 scrollTo 的 index 估算过冲 bug）
  final ScrollOffsetController _scrollOffsetController =
      ScrollOffsetController();

  /// 拼页模式：各图片的 GlobalKey（量取渲染高度/位置）
  final Map<int, GlobalKey> _imageKeys = {};
  GlobalKey _keyOf(int index) =>
      _imageKeys.putIfAbsent(index, () => GlobalKey(debugLabel: 'img_$index'));

  /// 拼页模式：监听各图片位置，用于定位当前页
  final ItemPositionsListener _itemPositionsListener =
      ItemPositionsListener.create();

  /// 拼页模式当前页码（滚动时实时更新，不触发 setState 重建列表）
  final ValueNotifier<int> _continuousPageNotifier = ValueNotifier(0);

  /// 是否首次加载（仅首次加载恢复续读页码，切章节不恢复）
  bool _isInitialLoad = true;

  /// 每次加载自增，作为列表 key 的一部分，确保 ScrollablePositionedList
  /// 每次加载都是全新实例（不复用 PageStorage 历史偏移），切章节/切回已读
  /// 章节都从第 0 页开始，避免连点切章节时页码停留在旧位置。
  int _loadId = 0;

  /// 拼页列表专用 PageStorage 桶，每次加载重建为空桶，使
  /// ScrollablePositionedList 的 initState 读 PageStorage 时拿到 null，
  /// 不再恢复历史滚动位置，切章节/切回已读章节都从第 0 页开始。
  PageStorageBucket _galleryBucket = PageStorageBucket();

  /// gallery 上次构建所用的阅读模式，用于检测模式切换以刷新 gallery。
  ReadingMode _builtMode = ReadingMode.pageTurn;

  /// gallery 上次构建所用的双页状态（横屏+开关+翻页模式），变化时重建 PageController。
  bool _builtDoublePage = false;

  /// 上次构建所用的墨水屏状态，变化时 rebuild 以切换滤镜/背景/动画。
  bool _builtInkMode = false;

  /// 墨水屏柔和底色（与图片白边同色 #D9D2CC，形成统一暖灰底）。
  static const Color _inkBgColor = Color(0xFFD9D2CC);

  /// 墨水屏灰度矩阵（×0.85 压暗 + 轻微暖调；白边处理后 = 背景色 #D9D2CC）。
  static const _inkGrayMatrix = <double>[
    0.254,
    0.499,
    0.097,
    0,
    0,
    0.246,
    0.484,
    0.094,
    0,
    0,
    0.239,
    0.469,
    0.091,
    0,
    0,
    0,
    0,
    0,
    1,
    0,
  ];

  /// 画廊背景：墨水屏用柔和暖灰（置于灰度罩外，暖色不受矩阵影响），否则黑。
  Color get _galleryBg =>
      SettingsService().inkScreenMode ? _inkBgColor : Colors.black;

  /// 画廊内部底色（PhotoView/dissolve）：墨水屏透明，露出罩外浅灰；否则黑。
  Color get _innerGalleryBg =>
      SettingsService().inkScreenMode ? Colors.transparent : Colors.black;

  /// 画廊上的文字色：墨水屏浅灰底用深灰，否则白。
  Color get _inkTextColor =>
      SettingsService().inkScreenMode ? Colors.black54 : Colors.white;

  /// 墨水屏灰度滤镜。
  ColorFilter get _inkColorFilter => ColorFilter.matrix(_inkGrayMatrix);

  /// 当前是否为拼页模式
  bool get _isContinuousMode => _effectiveReadingMode == ReadingMode.continuous;

  /// 当前是否为消散模式（逐页交叉淡入淡出）
  bool get _isDissolveMode => _effectiveReadingMode == ReadingMode.dissolve;

  /// 当前是否为从左往右翻页（PageView/PhotoViewGallery 反向，图片从左翻入）
  bool get _isReverseDirection =>
      _effectiveReadingMode == ReadingMode.leftToRight;

  /// 双页模式：翻页（含无动画）/消散模式 + 开关开启 + 横屏 时生效（拼页模式不支持）
  bool get _isDoublePage {
    if (_effectiveReadingMode != ReadingMode.pageTurn &&
        _effectiveReadingMode != ReadingMode.dissolve &&
        _effectiveReadingMode != ReadingMode.leftToRight &&
        _effectiveReadingMode != ReadingMode.none) {
      return false;
    }
    if (!ReaderOverrideService().effectiveDoublePageManga(
      widget.comic.pathWord,
    )) {
      return false;
    }
    return MediaQuery.orientationOf(context) == Orientation.landscape;
  }

  /// 双页 spread 映射（首页单独成页，保证跨页图不错位）：
  /// spread0=图0（单），spreadN(N>0)=图(2N-1)+图(2N)。
  int _imageToSpread(int imageIndex) =>
      imageIndex <= 0 ? 0 : (imageIndex + 1) ~/ 2;
  int _spreadLeftImage(int spread) => spread == 0 ? 0 : spread * 2 - 1;
  int _spreadRightImage(int spread) => spread * 2;
  int get _spreadCount => _images.isEmpty ? 0 : 1 + _images.length ~/ 2;
  int get _currentSpread => _imageToSpread(_currentIndex);
  int get _controllerInitialPage =>
      _isDoublePage ? _currentSpread : _currentIndex;

  /// 当前生效的漫画阅读模式：独立设置开启时取 per-item 覆盖，否则全局
  ReadingMode get _effectiveReadingMode =>
      ReaderOverrideService().effectiveMangaMode(widget.comic.pathWord);

  @override
  void initState() {
    super.initState();
    _currentChapter = widget.chapter;
    _currentIndex = widget.initialPage < 0 ? 0 : widget.initialPage;
    _pageController = PageController(initialPage: _currentIndex);
    _itemPositionsListener.itemPositions.addListener(_onItemPositionsChanged);
    SettingsService().addListener(_onReaderSettingsChanged);
    ReaderOverrideService().addListener(_onReaderSettingsChanged);
    _builtInkMode = SettingsService().inkScreenMode;
    // 沉浸阅读：延后到路由转场结束再隐藏顶部状态栏（保留底部导航栏），
    // 避免系统栏切换与 MaterialPageRoute 转场叠加造成进入卡顿。
    Future.delayed(const Duration(milliseconds: 350), () {
      if (!mounted) return;
      SystemChrome.setEnabledSystemUIMode(
        SystemUiMode.manual,
        overlays: [SystemUiOverlay.bottom],
      );
    });
    _loadImages();
    PlatformService.onVolumeKey = _onVolumeKey;
    PlatformService.setVolumeKeyNav(
      ReaderOverrideService().effectiveVolumeKeyTurnManga(
        widget.comic.pathWord,
      ),
    );
  }

  @override
  void dispose() {
    PlatformService.onVolumeKey = null;
    PlatformService.setVolumeKeyNav(false);
    _itemPositionsListener.itemPositions.removeListener(
      _onItemPositionsChanged,
    );
    SettingsService().removeListener(_onReaderSettingsChanged);
    ReaderOverrideService().removeListener(_onReaderSettingsChanged);
    _pageController.dispose();
    _continuousPageNotifier.dispose();
    // 离开阅读器：恢复状态栏（App 默认 edge-to-edge）
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    // 清理 blob 站临时文件（摸摸漫画等 useBlobBase64 站落盘的章节图）
    WebViewImageFetcher().clearBlobTempFiles();
    super.dispose();
  }

  /// 阅读（全局或独立）设置变化：阅读模式改变时刷新 gallery（重建控件、
  /// 重新定位当前页）；双页开关变化时 rebuild，由 _buildGallery 同步重建
  /// PageController；预加载/反转无需重建控件。
  void _onReaderSettingsChanged() {
    if (!mounted || _images.isEmpty) return;
    PlatformService.setVolumeKeyNav(
      ReaderOverrideService().effectiveVolumeKeyTurnManga(
        widget.comic.pathWord,
      ),
    );
    if (_effectiveReadingMode != _builtMode) {
      _refreshGallery();
      return;
    }
    if (_isDoublePage != _builtDoublePage) {
      setState(() {});
    }
    // 墨水屏开关变化：rebuild 以切换外包滤镜、纸张底、动画时长
    final s = SettingsService();
    if (s.inkScreenMode != _builtInkMode) {
      _builtInkMode = s.inkScreenMode;
      setState(() {});
    }
  }

  /// 刷新 gallery（模式切换用）：bump _loadId 重建全新实例、PageController
  /// 指向当前页；拼页模式 post-frame 跳到当前页。不重新拉图。
  void _refreshGallery() {
    final initialPage = _controllerInitialPage;
    final isDouble = _isDoublePage;
    setState(() {
      _loadId++; // 新 key，确保 gallery 全新实例
      _galleryBucket = PageStorageBucket(); // 空桶，杜绝历史偏移恢复
      _builtMode = _effectiveReadingMode;
      _builtDoublePage = isDouble;
    });
    _pageController = PageController(initialPage: initialPage);
    if (_isContinuousMode) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && _itemScrollController.isAttached) {
          _itemScrollController.jumpTo(index: _currentIndex);
        }
      });
    }
  }

  Future<void> _loadImages() async {
    setState(() {
      _isLoading = true;
      _error = null;
      _images = [];
      _useLocal = false;
      _loadId++; // 每次加载用新 key，确保列表全新实例
      _galleryBucket = PageStorageBucket(); // 空桶，杜绝历史偏移恢复
    });
    // 拼页模式：等一帧让"加载中"界面构建、旧列表释放，
    // 避免 ScrollablePositionedList 复用 ItemScrollController 时
    // 新列表 attach 早于旧列表 detach 触发断言崩溃（本地图片加载快时易发）
    if (_isContinuousMode) {
      final frameReady = Completer<void>();
      WidgetsBinding.instance.addPostFrameCallback(
        (_) => frameReady.complete(),
      );
      await frameReady.future;
      if (!mounted) return;
    }

    try {
      // 优先本地已下载图片（离线阅读）
      final local = await DownloadService().getLocalImages(
        widget.comic.pathWord,
        widget.comic.title,
        _currentChapter.id,
      );
      if (local.isNotEmpty) {
        setState(() {
          _images = local;
          _useLocal = true;
        });
        return;
      }
      // 回退网络加载：用漫画自身所属源（书架多源时 current 未必匹配）
      final source =
          (widget.comic.sourceId != null && widget.comic.sourceId!.isNotEmpty)
          ? (SourceManager().getSource(widget.comic.sourceId!) ??
                SourceManager().current)
          : SourceManager().current;
      final cchapter = comicChapterToCChapter(
        _currentChapter,
        source.id,
        widget.comic.pathWord,
      );
      final images = await source.getChapterImages(
        comicToCManga(widget.comic, source.id),
        cchapter,
      );
      final headers = <String, String>{...source.imageHeaders};
      final ref = source.refererForChapter(cchapter);
      if (ref != null) headers['Referer'] = ref;
      setState(() {
        _images = images;
        _imageHeaders = headers;
      });
    } catch (e) {
      setState(() {
        _error = e.toString();
      });
    } finally {
      if (mounted) {
        if (_images.isNotEmpty) {
          _currentIndex = _currentIndex.clamp(0, _images.length - 1);
          // 记录续读点与已读章节（仅图片成功加载时）
          ReadingProgressService().recordChapter(
            widget.comic.pathWord,
            _currentChapter,
            _currentIndex,
            _allChapters.indexWhere((c) => c.id == _currentChapter.id),
          );
          // 按进度归位"正在读"/"已读完"书架
          _applyReadingStatus();
        } else {
          _currentIndex = 0;
        }
        setState(() {
          _isLoading = false;
        });
        if (_isContinuousMode && _images.isNotEmpty) {
          if (_isInitialLoad && widget.initialPage > 0) {
            // 首次加载：恢复续读页
            final target = widget.initialPage.clamp(0, _images.length - 1);
            WidgetsBinding.instance.addPostFrameCallback((_) {
              if (_itemScrollController.isAttached) {
                _itemScrollController.jumpTo(index: target);
              }
            });
          } else {
            // 切章节：延迟 2 帧 jumpTo(0)。本地图片解码快、初始高度 0，
            // ScrollPosition 在 layout 修正时会被带偏到历史 offset；等 2 帧
            // position 稳定后强制重置到第 0 页。
            WidgetsBinding.instance.addPostFrameCallback((_) {
              WidgetsBinding.instance.addPostFrameCallback((_) {
                if (_itemScrollController.isAttached) {
                  _itemScrollController.jumpTo(index: 0);
                }
              });
            });
          }
        }
        if (_images.isNotEmpty) {
          _isInitialLoad = false;
        }
        // 在线阅读：开章/切章后预加载当前页之后的图片
        _preloadAhead(_currentIndex);
      }
    }
  }

  /// 在线阅读时预加载当前页之后的若干张图片，提升翻页流畅度。
  /// 仅网络图片生效（本地已下载图片读取快，无需预加载）；仅向前预加载。
  /// 数量由设置项 preloadImageCount 控制（2~10，默认5），独立设置开启时取 per-item。
  void _preloadAhead(int fromIndex) {
    if (_useLocal || _images.isEmpty) return;
    final count = ReaderOverrideService().effectivePreload(
      widget.comic.pathWord,
    );
    final end = (fromIndex + 1 + count).clamp(0, _images.length);
    for (var i = fromIndex + 1; i < end; i++) {
      final url = _images[i];
      if (url.startsWith('file://') || !url.contains('://')) {
        // blob 站临时文件预解码：限宽同展示路径
        final dw =
            (MediaQuery.sizeOf(context).width *
                    MediaQuery.devicePixelRatioOf(context))
                .round();
        final file = File(
          url.startsWith('file://') ? Uri.parse(url).toFilePath() : url,
        );
        precacheImage(
          ResizeImage(FileImage(file), width: dw, allowUpscaling: false),
          context,
        );
      } else if (url.startsWith('data:')) {
        // base64 图片预解码：限宽至屏幕物理像素（与展示路径的
        // Image.memory(cacheWidth) 同参数，命中同一缓存条目），
        // 避免全尺寸预解码大图叠加导致内存溢出
        final commaIdx = url.indexOf(',');
        if (commaIdx > 0) {
          final bytes = base64.decode(url.substring(commaIdx + 1));
          final dw =
              (MediaQuery.sizeOf(context).width *
                      MediaQuery.devicePixelRatioOf(context))
                  .round();
          precacheImage(
            ResizeImage(MemoryImage(bytes), width: dw, allowUpscaling: false),
            context,
          );
        }
      } else {
        precacheImage(
          CachedNetworkImageProvider(
            url,
            headers: _imageHeaders,
            cacheManager: comicImageCacheManager,
          ),
          context,
        );
      }
    }
  }

  /// 获取所有章节（展平）
  List<ComicChapter> get _allChapters {
    return widget.groups.expand((g) => g.chapters).toList();
  }

  /// 上一话（第一话时提示）
  void _prevChapter() {
    final allChapters = _allChapters;
    final currentIndex = allChapters.indexWhere(
      (c) => c.id == _currentChapter.id,
    );
    if (currentIndex <= 0) {
      _showTip('已经是第一话了');
      return;
    }
    _goToChapter(allChapters[currentIndex - 1]);
  }

  /// 下一话（最后一话时提示）
  void _nextChapter() {
    final allChapters = _allChapters;
    final currentIndex = allChapters.indexWhere(
      (c) => c.id == _currentChapter.id,
    );
    if (currentIndex < 0 || currentIndex >= allChapters.length - 1) {
      _showTip('已经是最后一话了');
      return;
    }
    _goToChapter(allChapters[currentIndex + 1]);
  }

  /// 切换到指定章节：重置页码与翻页控制器后重新加载
  void _goToChapter(ComicChapter chapter) {
    setState(() {
      _currentChapter = chapter;
      _currentIndex = 0;
      _continuousPageNotifier.value = 0; // 拼页模式：切章节页码归零
    });
    _pageController = PageController(initialPage: 0);
    _loadImages();
  }

  // ---------------- 阅读设置 ----------------

  /// 阅读设置弹层：独立设置开关 + 漫画阅读模式 + 在线预加载图片数。
  /// 草稿式，点「确认」一次性写入（独立设置开启写 per-item 覆盖，否则写全局）。
  void _showReaderSettingsSheet() {
    final pathWord = widget.comic.pathWord;
    final o = ReaderOverrideService();
    bool draftIndependent = o.isIndependentManga(pathWord);
    ReadingMode draftMode = o.effectiveMangaMode(pathWord);
    int draftPreload = o.effectivePreload(pathWord);
    bool draftReverseTap = o.effectiveReverseTapManga(pathWord);
    bool draftDoublePage = o.effectiveDoublePageManga(pathWord);
    bool draftShowHud = o.effectiveShowHudManga(pathWord);
    bool draftVolumeKey = o.effectiveVolumeKeyTurnManga(pathWord);
    bool draftInk = SettingsService().inkScreenMode; // 墨水屏仅全局，无 per-item 覆盖

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.black87,
      barrierColor: Colors.black54,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setSheet) {
          return SafeArea(
            child: SingleChildScrollView(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(20, 16, 20, 16),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Row(
                      children: [
                        const Text(
                          '阅读设置',
                          style: TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.bold,
                            color: Colors.white,
                          ),
                        ),
                        const Spacer(),
                        Text(
                          '独立设置',
                          style: TextStyle(
                            fontSize: 13,
                            color: draftIndependent
                                ? JellyTheme.primary
                                : Colors.white70,
                          ),
                        ),
                        Switch(
                          value: draftIndependent,
                          activeColor: JellyTheme.primary,
                          onChanged: (v) =>
                              setSheet(() => draftIndependent = v),
                        ),
                      ],
                    ),
                    Container(
                      margin: const EdgeInsets.only(bottom: 12),
                      padding: const EdgeInsets.symmetric(
                        horizontal: 10,
                        vertical: 6,
                      ),
                      decoration: BoxDecoration(
                        color: Colors.white.withValues(alpha: 0.06),
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Text(
                        draftIndependent ? '当前修改仅对本书生效' : '当前为全局设置，修改影响所有漫画',
                        style: TextStyle(
                          fontSize: 11,
                          color: draftIndependent
                              ? JellyTheme.primary.withValues(alpha: 0.9)
                              : Colors.white54,
                        ),
                      ),
                    ),
                    Row(
                      children: [
                        const Text(
                          '阅读模式',
                          style: TextStyle(fontSize: 14, color: Colors.white),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Row(
                            children: [
                              _modeChip(
                                '右左',
                                draftMode == ReadingMode.pageTurn,
                                () => setSheet(
                                  () => draftMode = ReadingMode.pageTurn,
                                ),
                              ),
                              const SizedBox(width: 8),
                              _modeChip(
                                '左右',
                                draftMode == ReadingMode.leftToRight,
                                () => setSheet(
                                  () => draftMode = ReadingMode.leftToRight,
                                ),
                              ),
                              const SizedBox(width: 8),
                              _modeChip(
                                '消散',
                                draftMode == ReadingMode.dissolve,
                                () => setSheet(
                                  () => draftMode = ReadingMode.dissolve,
                                ),
                              ),
                              const SizedBox(width: 8),
                              _modeChip(
                                '拼页',
                                draftMode == ReadingMode.continuous,
                                () => setSheet(
                                  () => draftMode = ReadingMode.continuous,
                                ),
                              ),
                              const SizedBox(width: 8),
                              _modeChip(
                                '无动画',
                                draftMode == ReadingMode.none,
                                () => setSheet(
                                  () => draftMode = ReadingMode.none,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 12),
                    Row(
                      children: [
                        const Text(
                          '预加载',
                          style: TextStyle(fontSize: 14, color: Colors.white),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Slider(
                            value: draftPreload.toDouble(),
                            min: SettingsService.minPreloadImages.toDouble(),
                            max: SettingsService.maxPreloadImages.toDouble(),
                            divisions:
                                SettingsService.maxPreloadImages -
                                SettingsService.minPreloadImages,
                            activeColor: JellyTheme.primary,
                            onChanged: (v) =>
                                setSheet(() => draftPreload = v.round()),
                          ),
                        ),
                        SizedBox(
                          width: 28,
                          child: Text(
                            '$draftPreload',
                            style: const TextStyle(
                              color: Colors.white,
                              fontWeight: FontWeight.bold,
                            ),
                            textAlign: TextAlign.center,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 12),
                    Row(
                      children: [
                        const Text(
                          '翻页反转',
                          style: TextStyle(fontSize: 14, color: Colors.white),
                        ),
                        const SizedBox(width: 12),
                        const Expanded(
                          child: Text(
                            '左点下一页、右点上一页',
                            style: TextStyle(
                              fontSize: 12,
                              color: Colors.white54,
                            ),
                          ),
                        ),
                        Switch(
                          value: draftReverseTap,
                          activeColor: JellyTheme.primary,
                          onChanged: (v) => setSheet(() => draftReverseTap = v),
                        ),
                      ],
                    ),
                    Row(
                      children: [
                        const Text(
                          '双页模式',
                          style: TextStyle(fontSize: 14, color: Colors.white),
                        ),
                        const SizedBox(width: 12),
                        const Expanded(
                          child: Text(
                            '横屏左右并排',
                            style: TextStyle(
                              fontSize: 12,
                              color: Colors.white54,
                            ),
                          ),
                        ),
                        Switch(
                          value: draftDoublePage,
                          activeColor: JellyTheme.primary,
                          onChanged: (v) => setSheet(() => draftDoublePage = v),
                        ),
                      ],
                    ),
                    Row(
                      children: [
                        const Text(
                          '信息栏',
                          style: TextStyle(fontSize: 14, color: Colors.white),
                        ),
                        const SizedBox(width: 12),
                        const Expanded(
                          child: Text(
                            '显示时间、页码、进度',
                            style: TextStyle(
                              fontSize: 12,
                              color: Colors.white54,
                            ),
                          ),
                        ),
                        Switch(
                          value: draftShowHud,
                          activeColor: JellyTheme.primary,
                          onChanged: (v) => setSheet(() => draftShowHud = v),
                        ),
                      ],
                    ),
                    Row(
                      children: [
                        const Text(
                          '音量键翻页',
                          style: TextStyle(fontSize: 14, color: Colors.white),
                        ),
                        const SizedBox(width: 12),
                        const Expanded(
                          child: Text(
                            '按音量上/下键翻页（会接管音量键）',
                            style: TextStyle(
                              fontSize: 12,
                              color: Colors.white54,
                            ),
                          ),
                        ),
                        Switch(
                          value: draftVolumeKey,
                          activeColor: JellyTheme.primary,
                          onChanged: (v) => setSheet(() => draftVolumeKey = v),
                        ),
                      ],
                    ),
                    Row(
                      children: [
                        const Text(
                          '墨水屏',
                          style: TextStyle(fontSize: 14, color: Colors.white),
                        ),
                        const SizedBox(width: 12),
                        const Expanded(
                          child: Text(
                            '黑白柔和显示',
                            style: TextStyle(
                              fontSize: 12,
                              color: Colors.white54,
                            ),
                          ),
                        ),
                        Switch(
                          value: draftInk,
                          activeColor: JellyTheme.primary,
                          onChanged: (v) => setSheet(() => draftInk = v),
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    Row(
                      children: [
                        TextButton(
                          onPressed: () => Navigator.pop(ctx),
                          style: TextButton.styleFrom(
                            foregroundColor: Colors.white70,
                          ),
                          child: const Text('取消'),
                        ),
                        const Spacer(),
                        FilledButton(
                          onPressed: () async {
                            await o.setIndependentManga(
                              pathWord,
                              draftIndependent,
                            );
                            await o.setMangaMode(pathWord, draftMode);
                            await o.setMangaPreload(pathWord, draftPreload);
                            await o.setMangaReverseTap(
                              pathWord,
                              draftReverseTap,
                            );
                            await o.setMangaDoublePage(
                              pathWord,
                              draftDoublePage,
                            );
                            await o.setMangaShowHud(pathWord, draftShowHud);
                            await o.setMangaVolumeKeyTurn(
                              pathWord,
                              draftVolumeKey,
                            );
                            await SettingsService().setInkScreenMode(draftInk);
                            if (ctx.mounted) Navigator.pop(ctx);
                          },
                          child: const Text('确认'),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          );
        },
      ),
    );
  }

  Widget _modeChip(String label, bool selected, VoidCallback onTap) {
    return Expanded(
      child: GestureDetector(
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(vertical: 8),
          decoration: BoxDecoration(
            color: selected
                ? JellyTheme.primary
                : Colors.white.withValues(alpha: 0.12),
            borderRadius: BorderRadius.circular(8),
          ),
          alignment: Alignment.center,
          child: Text(
            label,
            style: TextStyle(
              fontSize: 13,
              color: selected ? Colors.white : Colors.white70,
              fontWeight: selected ? FontWeight.bold : FontWeight.normal,
            ),
          ),
        ),
      ),
    );
  }

  // ---------------- 目录 ----------------

  /// 章节目录抽屉（同图书阅读器：右侧滑入，自动定位当前话）
  void _showToc() {
    final chapters = _allChapters;
    if (chapters.isEmpty) return;
    final drawerWidth = MediaQuery.sizeOf(context).width * 0.75;
    final currentIndex = chapters.indexWhere((c) => c.id == _currentChapter.id);
    final itemScrollController = ItemScrollController();
    showGeneralDialog(
      context: context,
      barrierDismissible: true,
      barrierLabel: '目录',
      transitionDuration: const Duration(milliseconds: 250),
      pageBuilder: (ctx, anim, secondaryAnim) {
        final isDark = Theme.of(ctx).brightness == Brightness.dark;
        final textColor = isDark
            ? Colors.white.withValues(alpha: 0.92)
            : JellyTheme.textPrimaryLight;
        final subColor = isDark
            ? Colors.white.withValues(alpha: 0.5)
            : JellyTheme.textSecondary;
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (itemScrollController.isAttached) {
            itemScrollController.jumpTo(index: currentIndex);
          }
        });
        return Align(
          alignment: Alignment.centerRight,
          child: Material(
            color: Colors.transparent,
            child: Container(
              width: drawerWidth,
              height: double.infinity,
              decoration: BoxDecoration(
                color: isDark ? JellyTheme.cardDark : JellyTheme.cardLight,
                borderRadius: const BorderRadius.only(
                  topLeft: Radius.circular(20),
                  bottomLeft: Radius.circular(20),
                ),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withValues(alpha: 0.25),
                    blurRadius: 30,
                    offset: const Offset(-4, 0),
                  ),
                ],
              ),
              child: SafeArea(
                child: Column(
                  children: [
                    Padding(
                      padding: const EdgeInsets.fromLTRB(20, 14, 8, 12),
                      child: Row(
                        children: [
                          const Text(
                            '目录',
                            style: TextStyle(
                              fontSize: 18,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                          const SizedBox(width: 8),
                          Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 8,
                              vertical: 2,
                            ),
                            decoration: BoxDecoration(
                              color: JellyTheme.primary.withValues(alpha: 0.15),
                              borderRadius: BorderRadius.circular(10),
                            ),
                            child: Text(
                              '${chapters.length} 话',
                              style: TextStyle(
                                fontSize: 11,
                                color: JellyTheme.primary,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                          ),
                          const Spacer(),
                          IconButton(
                            icon: Icon(
                              Icons.close_rounded,
                              size: 20,
                              color: subColor,
                            ),
                            onPressed: () => Navigator.pop(ctx),
                            visualDensity: VisualDensity.compact,
                          ),
                        ],
                      ),
                    ),
                    Divider(height: 1, color: subColor.withValues(alpha: 0.15)),
                    Expanded(
                      child: ScrollablePositionedList.builder(
                        itemScrollController: itemScrollController,
                        padding: const EdgeInsets.symmetric(vertical: 4),
                        itemCount: chapters.length,
                        itemBuilder: (ctx, i) {
                          final cur = i == currentIndex;
                          return Material(
                            color: Colors.transparent,
                            child: InkWell(
                              onTap: () {
                                Navigator.pop(ctx);
                                _goToChapter(chapters[i]);
                              },
                              child: Container(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 20,
                                  vertical: 12,
                                ),
                                decoration: cur
                                    ? BoxDecoration(
                                        color: JellyTheme.primary.withValues(
                                          alpha: 0.1,
                                        ),
                                        border: Border(
                                          left: BorderSide(
                                            color: JellyTheme.primary,
                                            width: 3,
                                          ),
                                        ),
                                      )
                                    : null,
                                child: Text(
                                  chapters[i].title,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                    fontSize: 14,
                                    color: cur ? JellyTheme.primary : textColor,
                                    fontWeight: cur
                                        ? FontWeight.w700
                                        : FontWeight.w400,
                                  ),
                                ),
                              ),
                            ),
                          );
                        },
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        );
      },
      transitionBuilder: (ctx, anim, secondaryAnim, child) {
        final offset = Tween<Offset>(
          begin: const Offset(1, 0),
          end: Offset.zero,
        ).animate(CurvedAnimation(parent: anim, curve: Curves.easeOutCubic));
        return SlideTransition(position: offset, child: child);
      },
    );
  }

  /// 按当前进度把漫画归位到"正在读"/"已读完"书架（幂等，带状态缓存避免频繁调用）。
  /// 读完判定：当前章最后一页 且 当前章是最后一话（无下一话，与 _nextChapter 一致）。
  /// 未读完时仅已读达阈值（readingShelfThreshold）才归位"正在读"，
  /// 不足阈值直接返回且不缓存，保证读到阈值章节时仍能触发归位。
  void _applyReadingStatus() {
    if (_images.isEmpty) return;
    final page = _isContinuousMode
        ? _continuousPageNotifier.value
        : (_isDoublePage ? _currentSpread : _currentIndex);
    final pageCount = _isDoublePage ? _spreadCount : _images.length;
    final allChapters = _allChapters;
    final ci = allChapters.indexWhere((c) => c.id == _currentChapter.id);
    final isLastChapter = ci < 0 || ci >= allChapters.length - 1;
    final finished = page + 1 >= pageCount && isLastChapter;
    final target = finished
        ? BookshelfService.presetFinished
        : BookshelfService.presetReading;
    if (!finished && !_useLocal) {
      // 未读完：在线阅读仅已读达阈值才归位"正在读"，避免瞟几眼污染；
      // 下载漫画（_useLocal）视为明确阅读意图，跳过阈值直接归位"正在读"。
      final seen =
          ReadingProgressService()
              .getProgress(widget.comic.pathWord)
              ?.seenChapterIds
              .length ??
          0;
      if (seen < ReadingProgressService.readingShelfThreshold) return;
    }
    if (_lastAppliedStatus == target) return;
    _lastAppliedStatus = target;
    ReadingProgressService().setFinished(
      widget.comic.pathWord,
      finished,
      meta: jsonEncode(widget.comic.toJson()),
    );
  }

  /// 简短提示
  void _showTip(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(msg), duration: const Duration(seconds: 1)),
    );
  }

  /// 切换控制栏显示
  void _toggleControls() {
    setState(() {
      _showControls = !_showControls;
    });
  }

  /// 点击翻页区域：左1/3 上一页/上一话，右1/3 下一页/下一话，中间切换控制栏
  /// 翻页反转开启时左右对调。
  /// 音量键翻页：下=下一页，上=上一页（复用点击翻页逻辑，覆盖所有模式+章节边界）。
  void _onVolumeKey(String dir) {
    if (!mounted || _images.isEmpty) return;
    dir == 'down' ? _onTapRight() : _onTapLeft();
  }

  void _handleTap(TapUpDetails details) {
    final size = MediaQuery.sizeOf(context);
    final dx = details.globalPosition.dx;
    // 从左往右模式自带方向反转；「翻页按钮反转」开关与之异或叠加
    final tapReverse =
        _isReverseDirection !=
        ReaderOverrideService().effectiveReverseTapManga(widget.comic.pathWord);
    final tapLeft = dx < size.width / 3;
    final tapRight = dx > size.width * 2 / 3;
    if (tapLeft) {
      tapReverse ? _onTapRight() : _onTapLeft();
    } else if (tapRight) {
      tapReverse ? _onTapLeft() : _onTapRight();
    } else {
      _toggleControls();
    }
  }

  void _onTapLeft() {
    if (_isContinuousMode) {
      _scrollUp();
      return;
    }
    if (_isDissolveMode) {
      if (_isDoublePage) {
        final spread = _currentSpread;
        if (spread > 0) {
          _goDissolvePage(_spreadLeftImage(spread - 1));
        } else {
          _prevChapter();
        }
        return;
      }
      if (_currentIndex > 0) {
        _goDissolvePage(_currentIndex - 1);
      } else {
        _prevChapter();
      }
      return;
    }
    final canPrev = _isDoublePage ? _currentSpread > 0 : _currentIndex > 0;
    if (canPrev) {
      _goAdjacentPage(-1);
    } else {
      _prevChapter();
    }
  }

  void _onTapRight() {
    if (_isContinuousMode) {
      _scrollDown();
      return;
    }
    if (_isDissolveMode) {
      if (_isDoublePage) {
        final spread = _currentSpread;
        if (spread < _spreadCount - 1) {
          _goDissolvePage(_spreadLeftImage(spread + 1));
        } else {
          _nextChapter();
        }
        return;
      }
      if (_currentIndex < _images.length - 1) {
        _goDissolvePage(_currentIndex + 1);
      } else {
        _nextChapter();
      }
      return;
    }
    final canNext = _isDoublePage
        ? _currentSpread < _spreadCount - 1
        : _currentIndex < _images.length - 1;
    if (canNext) {
      _goAdjacentPage(1);
    } else {
      _nextChapter();
    }
  }

  /// 翻页模式翻一页（[delta] -1 上一页 / 1 下一页）。无动画模式瞬切，其余平滑滑动。
  void _goAdjacentPage(int delta) {
    final controllerPage = _isDoublePage ? _currentSpread : _currentIndex;
    if (_effectiveReadingMode == ReadingMode.none) {
      _pageController.jumpToPage(controllerPage + delta);
      return;
    }
    delta < 0
        ? _pageController.previousPage(
            duration: const Duration(milliseconds: 250),
            curve: Curves.easeOutCubic,
          )
        : _pageController.nextPage(
            duration: const Duration(milliseconds: 250),
            curve: Curves.easeOutCubic,
          );
  }

  /// 消散模式：交叉淡入淡出到目标页（越界由调用方处理）
  void _goDissolvePage(int index) {
    ReadingProgressService().updatePageIndex(
      widget.comic.pathWord,
      _currentChapter.id,
      index,
    );
    setState(() => _currentIndex = index);
    _preloadAhead(index);
    _applyReadingStatus();
  }

  /// 拼页模式：翻到上一张（已在第一张时上一话）
  void _scrollUp() {
    if (!_itemScrollController.isAttached || _images.isEmpty) {
      return;
    }
    final current = _continuousPageNotifier.value;
    final prev = current - 1;
    if (prev < 0) {
      _prevChapter();
      return;
    }
    // 用 jumpTo 按索引重定位，不用像素级 animateScroll：
    // 上一页时上方图片可能正在解码(占位240->真实780)，像素偏移会因高度变化
    // 偏移到错误页（一次跳多页）。jumpTo 把目标页设为 center、offset 归零，
    // 上方图片事后解码不影响目标页位置。
    _itemScrollController.jumpTo(index: prev, alignment: 0);
  }

  /// 拼页模式：翻到下一张（已在最后一张时下一话）
  void _scrollDown() {
    if (!_itemScrollController.isAttached || _images.isEmpty) {
      return;
    }
    final current = _continuousPageNotifier.value;
    final next = current + 1;
    if (next >= _images.length) {
      _nextChapter();
      return;
    }
    final curBox = _renderBoxOf(current);
    if (curBox == null) {
      // 当前页未布局，回退瞬切
      _itemScrollController.jumpTo(index: next, alignment: 0);
      _setCurrentPage(next);
      return;
    }
    // 像素级平滑滚动到当前页底部 = 下一页顶部对齐视口顶：当前页顶部 y + 当前页高度
    final curTopY = curBox.localToGlobal(Offset.zero).dy;
    final offset = curTopY + curBox.size.height;
    _scrollOffsetController.animateScroll(
      offset: offset,
      duration: const Duration(milliseconds: 250),
      curve: Curves.easeOutCubic,
    );
  }

  /// 取指定 index 图片的 RenderBox（未构建/未布局返回 null）
  RenderBox? _renderBoxOf(int index) {
    final ctx = _keyOf(index).currentContext;
    final ro = ctx?.findRenderObject();
    if (ro is RenderBox && ro.hasSize) return ro;
    return null;
  }

  /// 更新拼页当前页码并记录续读进度（值未变时不触发，避免列表重建）
  void _setCurrentPage(int idx) {
    if (idx == _continuousPageNotifier.value) return;
    _continuousPageNotifier.value = idx;
    _currentIndex =
        idx; // 同步 _currentIndex，切模式时 _refreshGallery/_controllerInitialPage 才能拿到正确位置
    ReadingProgressService().updatePageIndex(
      widget.comic.pathWord,
      _currentChapter.id,
      idx,
    );
    _preloadAhead(idx);
    _applyReadingStatus();
  }

  /// 拼页模式：根据各图片实际渲染位置，取视口顶部所在图片更新页码与续读进度。
  /// 用 GlobalKey + localToGlobal 量真实屏幕位置，不依赖 ItemPosition.edge
  /// （scrollable_positioned_list 0.3.8 的 edge 由 getOffsetToReveal 计算不可靠，
  /// 会让 notifier 指向不在视口的页，进而让翻页算出反向 offset）。
  void _onItemPositionsChanged() {
    if (_images.isEmpty) return;
    final positions = _itemPositionsListener.itemPositions.value;
    if (positions.isEmpty) return;
    final viewportH = MediaQuery.sizeOf(context).height;
    int? topIndex;
    double bestY = -double.infinity;
    int? topmostIndex; // 兜底：可见页里 y 最小（最靠上）的那页
    double topmostY = double.infinity;
    int maxIndex = -1;
    double maxIndexBottom = -double.infinity;
    double maxIndexH = 0; // maxIndex 项高度（末页未加载时为 0，用于排除假到底）
    for (final p in positions) {
      final box = _renderBoxOf(p.index);
      if (box == null) {
        continue;
      }
      final y = box.localToGlobal(Offset.zero).dy;
      final h = box.size.height;
      if (p.index > maxIndex) {
        maxIndex = p.index;
        maxIndexBottom = y + h;
        maxIndexH = h;
      }
      // 顶部页：顶部在视口顶或上方(y<=0)且底部在视口内(y+h>0)，取最接近视口顶的
      if (y <= 0 && y + h > 0 && y > bestY) {
        bestY = y;
        topIndex = p.index;
      }
      // 兜底候选：最靠上的可见页（y 最小）
      if (y < topmostY) {
        topmostY = y;
        topmostIndex = p.index;
      }
    }
    // 底部判定：最后一张图可见且其底部未超出视口底（列表到底，末页矮图无法到顶）
    // 末页底部可能因亚像素/回弹取整略大于 viewportH，留 2px 容差避免漏判；
    // 末页必须已加载(h>0)，未加载的 0 高度占位项不算到底
    final hitBottom =
        maxIndex == _images.length - 1 &&
        maxIndexH > 0 &&
        maxIndexBottom <= viewportH + 2;
    if (hitBottom) {
      _setCurrentPage(_images.length - 1);
      return;
    }
    // 兜底：没有页跨视口顶时（视口顶恰在某页顶部附近、且上一页已被列表回收），
    // 取最靠上的可见页，避免 notifier 停留在已滚出屏幕的旧页导致翻页失灵/页码错乱
    final picked = topIndex ?? topmostIndex;
    if (picked != null) _setCurrentPage(picked);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: _galleryBg,
      body: Stack(children: [_buildGallery(), _buildHud(), _buildControls()]),
    );
  }

  Widget _buildGallery() {
    if (_isLoading) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            CircularProgressIndicator(),
            SizedBox(height: 16),
            Text('加载中...', style: TextStyle(color: _inkTextColor)),
          ],
        ),
      );
    }

    if (_error != null) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Icon(Icons.error_outline, size: 48, color: Colors.red),
            const SizedBox(height: 16),
            Text('加载失败: $_error', style: TextStyle(color: _inkTextColor)),
            const SizedBox(height: 16),
            ElevatedButton(onPressed: _loadImages, child: const Text('重试')),
          ],
        ),
      );
    }

    if (_images.isEmpty) {
      return Center(
        child: Text('暂无图片', style: TextStyle(color: _inkTextColor)),
      );
    }

    // 双页状态变化（横屏切换 / 双页开关变化）：同步重建 PageController
    // + gallery 实例。_currentIndex 保持 image index，initialPage 转 spread。
    if (_isDoublePage != _builtDoublePage) {
      _builtDoublePage = _isDoublePage;
      _pageController = PageController(initialPage: _controllerInitialPage);
      _loadId++;
      _galleryBucket = PageStorageBucket();
    }
    final Widget gallery = _isContinuousMode
        ? _buildContinuousGallery()
        : _isDissolveMode
        ? _buildDissolveGallery()
        : _buildPagedGallery();
    _builtMode = _effectiveReadingMode;
    // 章节加载完成时淡入过渡
    // 外层 PageStorage 用每次加载重建的空桶，让 ScrollablePositionedList
    // initState 读 PageStorage 拿到 null，从第 0 页开始（不恢复历史偏移）
    final Widget galleryWidget = PageStorage(
      bucket: _galleryBucket,
      child: TweenAnimationBuilder<double>(
        key: PageStorageKey<String>('fade_${_currentChapter.id}_$_loadId'),
        tween: Tween(begin: 0.0, end: 1.0),
        duration: const Duration(milliseconds: 250),
        curve: Curves.easeOut,
        builder: (context, v, child) => Opacity(opacity: v, child: child),
        child: gallery,
      ),
    );
    // 墨水屏模式：纸张色背景置于灰度罩外（保留暖意），滤镜只作用于图片；
    // 各画廊内部底色（PhotoView/dissolve）墨水屏下设透明，露出此处纸色。
    if (!SettingsService().inkScreenMode) return galleryWidget;
    return ColoredBox(
      color: _galleryBg,
      child: ColorFiltered(colorFilter: _inkColorFilter, child: galleryWidget),
    );
  }

  /// 翻页模式：PhotoViewGallery 逐页翻页（横向=左右翻页，竖向=上下翻页）
  Widget _buildPagedGallery({Axis scrollDirection = Axis.horizontal}) {
    if (_isDoublePage) return _buildDoublePageGallery();
    return GestureDetector(
      onTapUp: _handleTap,
      child: PhotoViewGallery.builder(
        scrollDirection: scrollDirection,
        reverse: _isReverseDirection,
        scrollPhysics: const ClampingScrollPhysics(),
        builder: (context, index) {
          return PhotoViewGalleryPageOptions(
            imageProvider: _useLocal
                ? FileImage(File(_images[index]))
                : _imageProviderOf(_images[index]),
            initialScale: PhotoViewComputedScale.contained,
            minScale: PhotoViewComputedScale.contained,
            maxScale: PhotoViewComputedScale.covered * 2,
            heroAttributes: PhotoViewHeroAttributes(tag: 'image_$index'),
            errorBuilder: (context, error, stackTrace) => Center(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  const Icon(Icons.broken_image, size: 48, color: Colors.grey),
                  const SizedBox(height: 8),
                  Text(
                    '第 ${index + 1} 页加载失败',
                    style: const TextStyle(color: Colors.grey),
                  ),
                ],
              ),
            ),
          );
        },
        itemCount: _images.length,
        loadingBuilder: (context, event) => Center(
          child: SizedBox(
            width: 30,
            height: 30,
            child: CircularProgressIndicator(
              value: event == null
                  ? 0
                  : event.cumulativeBytesLoaded /
                        (event.expectedTotalBytes ?? 1),
            ),
          ),
        ),
        backgroundDecoration: BoxDecoration(color: _innerGalleryBg),
        pageController: _pageController,
        onPageChanged: (index) {
          ReadingProgressService().updatePageIndex(
            widget.comic.pathWord,
            _currentChapter.id,
            index,
          );
          setState(() {
            _currentIndex = index;
          });
          _preloadAhead(index);
          _applyReadingStatus();
        },
      ),
    );
  }

  /// 双页模式：PageView 逐 spread 翻页，每 spread 左右并排两图（首页单独）
  Widget _buildDoublePageGallery() {
    return GestureDetector(
      onTapUp: _handleTap,
      child: PageView.builder(
        controller: _pageController,
        reverse: _isReverseDirection,
        physics: const ClampingScrollPhysics(),
        itemCount: _spreadCount,
        onPageChanged: (spread) {
          final imageIndex = _spreadLeftImage(spread);
          ReadingProgressService().updatePageIndex(
            widget.comic.pathWord,
            _currentChapter.id,
            imageIndex,
          );
          setState(() {
            _currentIndex = imageIndex;
          });
          _preloadAhead(imageIndex);
          _applyReadingStatus();
        },
        itemBuilder: (context, spread) => _buildSpread(spread),
      ),
    );
  }

  /// 双页 spread：首页或末尾单图时单图占满，否则左右两图并排
  /// 左图贴右、右图贴左，让竖图 contain 后多余黑边留到屏幕外侧而非中间。
  Widget _buildSpread(int spread) {
    final left = _spreadLeftImage(spread);
    final right = _spreadRightImage(spread);
    final hasRight = right < _images.length;
    if (spread == 0 || !hasRight) {
      return _buildSingleImage(spread == 0 ? 0 : left);
    }
    // 从左往右：左右镜像（图号交换），alignment 不变仍贴中缝，跨页不错位
    final leftImg = _isReverseDirection ? right : left;
    final rightImg = _isReverseDirection ? left : right;
    return Row(
      children: [
        Expanded(
          child: _buildSingleImage(leftImg, alignment: Alignment.centerRight),
        ),
        const SizedBox(width: 2),
        Expanded(
          child: _buildSingleImage(rightImg, alignment: Alignment.centerLeft),
        ),
      ],
    );
  }

  /// 构建在线图片 ImageProvider：data: URL 用 MemoryImage，其余用 CachedNetworkImageProvider。
  ImageProvider _imageProviderOf(String url) {
    if (url.startsWith('data:')) {
      final commaIdx = url.indexOf(',');
      final data = commaIdx > 0 ? url.substring(commaIdx + 1) : '';
      return MemoryImage(base64.decode(data));
    }
    return CachedNetworkImageProvider(
      url,
      headers: _imageHeaders,
      cacheManager: comicImageCacheManager,
    );
  }

  /// 构建在线图片 Widget：file:// 用 Image.file，data: URL 用 Image.memory，
  /// 其余用 CachedNetworkImage。
  /// blob 站（如摸摸漫画）图片经 WebView 转 base64 落盘临时文件，走 file:// 分支。
  Widget _buildOnlineImage(
    String url, {
    Key? key,
    BoxFit fit = BoxFit.contain,
    Alignment alignment = Alignment.center,
    double? width,
    int? memCacheWidth,
    Duration fadeInDuration = Duration.zero,
    Duration fadeOutDuration = Duration.zero,
    Widget Function(BuildContext, String)? placeholder,
    Widget Function(BuildContext, String, dynamic)? errorWidget,
  }) {
    if (url.startsWith('file://') || !url.contains('://')) {
      // blob 站落盘临时文件路径 — 用 Image.file + cacheWidth 限解码分辨率
      final file = File(
        url.startsWith('file://') ? Uri.parse(url).toFilePath() : url,
      );
      return Image.file(
        file,
        key: key,
        fit: fit,
        alignment: alignment,
        width: width,
        cacheWidth: memCacheWidth,
        frameBuilder: (context, child, frame, wasSynchronouslyLoaded) {
          if (wasSynchronouslyLoaded || frame != null) return child;
          return placeholder?.call(context, url) ??
              const Center(
                child: SizedBox(
                  width: 30,
                  height: 30,
                  child: CircularProgressIndicator(),
                ),
              );
        },
        errorBuilder: (context, error, stackTrace) =>
            errorWidget?.call(context, url, error) ?? _buildBrokenImage(-1),
      );
    }
    if (url.startsWith('data:')) {
      // data:image/xxx;base64,... — 直接用 Image.memory 解码
      final commaIdx = url.indexOf(',');
      final data = commaIdx > 0 ? url.substring(commaIdx + 1) : '';
      final bytes = base64.decode(data);
      return Image.memory(
        bytes,
        key: key,
        fit: fit,
        alignment: alignment,
        width: width,
        cacheWidth: memCacheWidth,
        frameBuilder: (context, child, frame, wasSynchronouslyLoaded) {
          if (wasSynchronouslyLoaded || frame != null) return child;
          return placeholder?.call(context, url) ??
              const Center(
                child: SizedBox(
                  width: 30,
                  height: 30,
                  child: CircularProgressIndicator(),
                ),
              );
        },
        errorBuilder: (context, error, stackTrace) =>
            errorWidget?.call(context, url, error) ?? _buildBrokenImage(-1),
      );
    }
    return CachedNetworkImage(
      key: key,
      imageUrl: url,
      httpHeaders: _imageHeaders,
      cacheManager: comicImageCacheManager,
      fit: fit,
      alignment: alignment,
      width: width,
      memCacheWidth: memCacheWidth,
      fadeInDuration: fadeInDuration,
      fadeOutDuration: fadeOutDuration,
      placeholder: placeholder,
      errorWidget: errorWidget,
    );
  }

  /// 双页模式单图：在线用 CachedNetworkImage，本地用 Image.file
  Widget _buildSingleImage(
    int index, {
    Alignment alignment = Alignment.center,
  }) {
    // 限制解码分辨率至屏幕物理宽度（与消散/拼页模式一致），
    // 避免 data: 大图全尺寸解码撑爆内存（blob 站整章 base64 已占大量堆）
    final dw =
        (MediaQuery.sizeOf(context).width *
                MediaQuery.devicePixelRatioOf(context))
            .round();
    if (_useLocal) {
      return Image.file(
        File(_images[index]),
        fit: BoxFit.contain,
        alignment: alignment,
        cacheWidth: dw,
        errorBuilder: (c, e, s) => _buildBrokenImage(index),
      );
    }
    return _buildOnlineImage(
      _images[index],
      fit: BoxFit.contain,
      alignment: alignment,
      memCacheWidth: dw,
      placeholder: (c, u) => const Center(
        child: SizedBox(
          width: 30,
          height: 30,
          child: CircularProgressIndicator(),
        ),
      ),
      errorWidget: (c, u, e) => _buildBrokenImage(index),
    );
  }

  /// 消散模式：逐页显示，换页时旧页淡出、新页淡入（交叉淡入淡出）
  Widget _buildDissolveGallery() {
    return GestureDetector(
      onTapUp: _handleTap,
      child: ColoredBox(
        color: _innerGalleryBg,
        child: AnimatedSwitcher(
          duration: SettingsService().inkScreenMode
              ? Duration.zero
              : const Duration(milliseconds: 600),
          switchInCurve: Curves.easeInOut,
          switchOutCurve: Curves.easeInOut,
          transitionBuilder: (child, anim) =>
              FadeTransition(opacity: anim, child: child),
          child: _isDoublePage
              ? _buildDissolveSpread(_currentSpread)
              : _buildDissolveImage(_currentIndex),
        ),
      ),
    );
  }

  /// 消散模式双页 spread：首页或末尾单图时单图占满，否则左右两图并排。
  /// 外层 SizedBox.expand 用 spread 做 key 触发 AnimatedSwitcher 交叉淡入淡出。
  /// 左图贴右、右图贴左，让竖图 contain 后多余黑边留到屏幕外侧而非中间。
  Widget _buildDissolveSpread(int spread) {
    final left = _spreadLeftImage(spread);
    final right = _spreadRightImage(spread);
    final hasRight = right < _images.length;
    final Widget content;
    if (spread == 0 || !hasRight) {
      content = _buildDissolveImage(spread == 0 ? 0 : left, standalone: false);
    } else {
      // 从左往右：左右镜像（图号交换），alignment 不变仍贴中缝
      final leftImg = _isReverseDirection ? right : left;
      final rightImg = _isReverseDirection ? left : right;
      content = Row(
        children: [
          Expanded(
            child: _buildDissolveImage(
              leftImg,
              standalone: false,
              alignment: Alignment.centerRight,
            ),
          ),
          const SizedBox(width: 2),
          Expanded(
            child: _buildDissolveImage(
              rightImg,
              standalone: false,
              alignment: Alignment.centerLeft,
            ),
          ),
        ],
      );
    }
    return SizedBox.expand(
      key: ValueKey('dissolve_spread_$spread'),
      child: content,
    );
  }

  /// 消散模式单页图（按 index 取 key，AnimatedSwitcher 据此触发交叉淡入淡出）
  Widget _buildDissolveImage(
    int index, {
    bool standalone = true,
    Alignment alignment = Alignment.center,
  }) {
    if (index < 0 || index >= _images.length) {
      return const SizedBox.shrink();
    }
    // 限制解码分辨率至屏幕物理宽度，避免大图（如 2244×2717）解码出 ~24MB 副本
    final dw =
        (MediaQuery.sizeOf(context).width *
                MediaQuery.devicePixelRatioOf(context))
            .round();
    final Widget image;
    if (_useLocal) {
      image = Image.file(
        File(_images[index]),
        fit: BoxFit.contain,
        alignment: alignment,
        cacheWidth: dw,
        errorBuilder: (context, error, stackTrace) => _buildBrokenImage(index),
      );
    } else {
      image = _buildOnlineImage(
        _images[index],
        fit: BoxFit.contain,
        alignment: alignment,
        memCacheWidth: dw,
        fadeInDuration: Duration.zero,
        fadeOutDuration: Duration.zero,
        placeholder: (context, url) => const Center(
          child: SizedBox(
            width: 30,
            height: 30,
            child: CircularProgressIndicator(),
          ),
        ),
        errorWidget: (context, url, error) => _buildBrokenImage(index),
      );
    }
    return SizedBox.expand(
      key: standalone ? ValueKey(index) : null,
      child: image,
    );
  }

  /// 拼页模式：所有图片纵向连续滚动，按索引定位/翻页
  Widget _buildContinuousGallery() {
    return GestureDetector(
      onTapUp: _handleTap,
      child: ScrollablePositionedList.builder(
        itemScrollController: _itemScrollController,
        itemPositionsListener: _itemPositionsListener,
        scrollOffsetController: _scrollOffsetController,
        physics: const BouncingScrollPhysics(),
        padding: EdgeInsets.zero,
        itemCount: _images.length,
        itemBuilder: (context, index) => _buildContinuousImage(index),
      ),
    );
  }

  Widget _buildContinuousImage(int index) {
    // GlobalKey 用于量取图片渲染高度（拼页上一页像素偏移换算需要）
    final imageKey = _keyOf(index);
    // 限制解码分辨率至屏幕物理宽度，避免大图解码出超大副本占用内存
    final dw =
        (MediaQuery.sizeOf(context).width *
                MediaQuery.devicePixelRatioOf(context))
            .round();
    if (_useLocal) {
      return Image.file(
        File(_images[index]),
        key: imageKey,
        fit: BoxFit.contain,
        width: double.infinity,
        cacheWidth: dw,
        // 解码前 frame 为 null，显示固定高度占位，避免初始高度 0 触发
        // ScrollablePositionedList 的定位 bug（本地图片特有）。解码后切回真实图片。
        frameBuilder: (context, child, frame, wasSynchronouslyLoaded) {
          if (wasSynchronouslyLoaded || frame != null) {
            return child;
          }
          return const SizedBox(
            height: 240,
            child: Center(child: CircularProgressIndicator()),
          );
        },
        errorBuilder: (context, error, stackTrace) => _buildBrokenImage(index),
      );
    }
    return _buildOnlineImage(
      _images[index],
      key: imageKey,
      fit: BoxFit.contain,
      width: double.infinity,
      memCacheWidth: dw,
      fadeInDuration: Duration.zero,
      fadeOutDuration: Duration.zero,
      placeholder: (context, url) => const SizedBox(
        height: 240,
        child: Center(child: CircularProgressIndicator()),
      ),
      errorWidget: (context, url, error) => _buildBrokenImage(index),
    );
  }

  Widget _buildBrokenImage(int index) {
    return SizedBox(
      width: double.infinity,
      height: 240,
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const Icon(Icons.broken_image, size: 48, color: Colors.grey),
          const SizedBox(height: 8),
          Text(
            '第 ${index + 1} 页加载失败',
            style: const TextStyle(color: Colors.grey),
          ),
        ],
      ),
    );
  }

  /// 底部页码：拼页模式用 ValueListenableBuilder 局部刷新，避免列表重建
  Widget _buildPageIndicator() {
    const style = TextStyle(color: Colors.white);
    if (_isContinuousMode) {
      return ValueListenableBuilder<int>(
        valueListenable: _continuousPageNotifier,
        builder: (context, idx, child) =>
            Text('${idx + 1} / ${_images.length}', style: style),
      );
    }
    if (_isDoublePage) {
      final left = _currentIndex + 1;
      final right = _spreadRightImage(_currentSpread);
      final hasRight = right < _images.length;
      final text = hasRight
          ? '$left-${right + 1} / ${_images.length}'
          : '$left / ${_images.length}';
      return Text(text, style: style);
    }
    return Text('${_currentIndex + 1} / ${_images.length}', style: style);
  }

  // ---------------- 常驻信息栏（时间 / 页码 / 进度 / 漫画名） ----------------

  /// 常驻 HUD：左上时钟、右上页码、左下漫画名、右下进度百分比。
  /// ListenableBuilder 自响应设置变化，关闭时返回空 widget。
  Widget _buildHud() {
    return ListenableBuilder(
      listenable: Listenable.merge([
        SettingsService(),
        ReaderOverrideService(),
      ]),
      builder: (context, _) {
        if (!ReaderOverrideService().effectiveShowHudManga(
          widget.comic.pathWord,
        )) {
          return const SizedBox.shrink();
        }
        final style = TextStyle(
          fontSize: 11,
          color: Colors.white.withValues(alpha: 0.5),
          shadows: const [
            Shadow(
              color: Colors.black54,
              blurRadius: 2,
              offset: Offset(0.5, 0.5),
            ),
          ],
        );
        final padTop = MediaQuery.paddingOf(context).top + 8;
        final padBottom = MediaQuery.paddingOf(context).bottom + 8;
        const padH = 16.0;
        return IgnorePointer(
          child: Stack(
            fit: StackFit.expand,
            children: [
              Positioned(
                top: padTop,
                left: padH,
                child: _ClockText(style: style),
              ),
              Positioned(
                top: padTop,
                right: padH,
                child: _buildHudPageText(style),
              ),
              Positioned(
                bottom: padBottom,
                left: padH,
                right: padH,
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        widget.comic.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: style,
                      ),
                    ),
                    _buildHudPctText(style),
                  ],
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _buildHudPageText(TextStyle style) {
    if (_images.isEmpty) return const SizedBox.shrink();
    if (_isContinuousMode) {
      return ValueListenableBuilder<int>(
        valueListenable: _continuousPageNotifier,
        builder: (_, idx, _) =>
            Text('${idx + 1} / ${_images.length}', style: style),
      );
    }
    return Text(_pageText(_currentIndex), style: style);
  }

  Widget _buildHudPctText(TextStyle style) {
    if (_images.isEmpty) return const SizedBox.shrink();
    if (_isContinuousMode) {
      return ValueListenableBuilder<int>(
        valueListenable: _continuousPageNotifier,
        builder: (_, idx, _) {
          final pct = ((idx + 1) / _images.length * 100)
              .clamp(0, 100)
              .toStringAsFixed(0);
          return Text('$pct%', style: style);
        },
      );
    }
    final pct = ((_currentIndex + 1) / _images.length * 100)
        .clamp(0, 100)
        .toStringAsFixed(0);
    return Text('$pct%', style: style);
  }

  String _pageText(int idx) {
    if (_images.isEmpty) return '';
    if (_isDoublePage) {
      final left = idx + 1;
      final right = _spreadRightImage(_imageToSpread(idx));
      final hasRight = right < _images.length;
      return hasRight
          ? '$left-${right + 1} / ${_images.length}'
          : '$left / ${_images.length}';
    }
    return '${idx + 1} / ${_images.length}';
  }

  Widget _buildControls() {
    return AnimatedOpacity(
      opacity: _showControls ? 1.0 : 0.0,
      duration: const Duration(milliseconds: 200),
      child: IgnorePointer(
        ignoring: !_showControls,
        child: Column(
          children: [
            // 顶部栏
            AppBar(
              backgroundColor: Colors.black87,
              title: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    widget.comic.title,
                    style: const TextStyle(fontSize: 14, color: Colors.grey),
                  ),
                  Text(
                    _currentChapter.title,
                    style: const TextStyle(fontSize: 12, color: Colors.grey),
                  ),
                ],
              ),
              iconTheme: const IconThemeData(color: Colors.white),
            ),
            const Spacer(),
            // 底部栏：颜色铺到底部边缘，SafeArea 抬高内容避开系统导航栏/手势条
            Container(
              color: Colors.black87,
              child: SafeArea(
                top: false,
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      // 页码滑块（拼页模式下不显示）
                      if (_images.isNotEmpty && !_isContinuousMode)
                        Slider(
                          value:
                              (_isDoublePage ? _currentSpread : _currentIndex)
                                  .toDouble(),
                          min: 0,
                          max:
                              (_isDoublePage
                                      ? _spreadCount - 1
                                      : _images.length - 1)
                                  .toDouble(),
                          onChanged: (value) {
                            setState(() {
                              if (_isDoublePage) {
                                _currentIndex = _spreadLeftImage(value.toInt());
                              } else {
                                _currentIndex = value.toInt();
                              }
                            });
                          },
                          onChangeEnd: (value) {
                            // 拖动/点击结束：跳转到目标页（onPageChanged 会同步 _currentIndex 与进度）
                            if (_pageController.hasClients) {
                              _pageController.jumpToPage(value.toInt());
                            }
                          },
                        ),
                      const SizedBox(height: 8),
                      // 页码和按钮（纯图标）
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                        children: [
                          TextButton(
                            onPressed: _prevChapter,
                            child: const Icon(
                              Icons.chevron_left,
                              color: Colors.white,
                            ),
                          ),
                          _buildPageIndicator(),
                          TextButton(
                            onPressed: _nextChapter,
                            child: const Icon(
                              Icons.chevron_right,
                              color: Colors.white,
                            ),
                          ),
                        ],
                      ),
                      // 设置 + 目录按钮（纯图标，右对齐，同图书阅读器）
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          // 左侧占位，宽度≈右侧两按钮，使番茄按钮居中
                          const SizedBox(width: 96),
                          const PomodoroButton(),
                          Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              TextButton(
                                onPressed: _showReaderSettingsSheet,
                                child: const Icon(
                                  Icons.settings_rounded,
                                  color: Colors.white,
                                ),
                              ),
                              TextButton(
                                onPressed: _showToc,
                                child: const Icon(
                                  Icons.menu_book_rounded,
                                  color: Colors.white,
                                ),
                              ),
                            ],
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ClockText extends StatefulWidget {
  final TextStyle style;
  const _ClockText({required this.style});

  @override
  State<_ClockText> createState() => _ClockTextState();
}

class _ClockTextState extends State<_ClockText> {
  Timer? _timer;
  String _time = '';

  @override
  void initState() {
    super.initState();
    _update();
    _timer = Timer.periodic(const Duration(seconds: 30), (_) => _update());
  }

  void _update() {
    final now = DateTime.now();
    final t =
        '${now.hour.toString().padLeft(2, '0')}:${now.minute.toString().padLeft(2, '0')}';
    if (t != _time) setState(() => _time = t);
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Text(_time, style: widget.style);
}
