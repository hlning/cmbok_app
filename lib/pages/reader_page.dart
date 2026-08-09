import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:photo_view/photo_view.dart';
import 'package:photo_view/photo_view_gallery.dart';
import 'package:scrollable_positioned_list/scrollable_positioned_list.dart';
import '../models/comic.dart';
import '../services/bookshelf_service.dart';
import '../services/comic_api.dart';
import '../services/download_service.dart';
import '../services/reading_progress_service.dart';
import '../services/settings_service.dart';
import '../theme/jelly_theme.dart';

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
  final ComicApi _api = ComicApi();

  late ComicChapter _currentChapter;
  List<String> _images = [];
  bool _isLoading = true;
  String? _error;
  int _currentIndex = 0;

  /// 最近一次归位的书架状态（presetReading/presetFinished），避免频繁移动
  String? _lastAppliedStatus;
  bool _showControls = true;
  bool _useLocal = false; // 是否使用本地已下载图片

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

  /// 当前是否为拼页模式
  bool get _isContinuousMode =>
      SettingsService().readingMode == ReadingMode.continuous;

  /// 当前是否为消散模式（逐页交叉淡入淡出）
  bool get _isDissolveMode =>
      SettingsService().readingMode == ReadingMode.dissolve;

  @override
  void initState() {
    super.initState();
    _currentChapter = widget.chapter;
    _currentIndex = widget.initialPage < 0 ? 0 : widget.initialPage;
    _pageController = PageController(initialPage: _currentIndex);
    _itemPositionsListener.itemPositions.addListener(_onItemPositionsChanged);
    _loadImages();
  }

  @override
  void dispose() {
    _itemPositionsListener.itemPositions.removeListener(
      _onItemPositionsChanged,
    );
    _pageController.dispose();
    _continuousPageNotifier.dispose();
    super.dispose();
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
      // 回退网络加载
      final images = await _api.getChapterImages(
        widget.comic.pathWord,
        _currentChapter.id,
      );
      setState(() {
        _images = images;
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
  /// 数量由设置项 preloadImageCount 控制（2~10，默认5）。
  void _preloadAhead(int fromIndex) {
    if (_useLocal || _images.isEmpty) return;
    final count = SettingsService().preloadImageCount;
    final end = (fromIndex + 1 + count).clamp(0, _images.length);
    for (var i = fromIndex + 1; i < end; i++) {
      precacheImage(CachedNetworkImageProvider(_images[i]), context);
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
        : _currentIndex;
    final allChapters = _allChapters;
    final ci = allChapters.indexWhere((c) => c.id == _currentChapter.id);
    final isLastChapter = ci < 0 || ci >= allChapters.length - 1;
    final finished = page + 1 >= _images.length && isLastChapter;
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
  void _handleTap(TapUpDetails details) {
    final size = MediaQuery.sizeOf(context);
    final dx = details.globalPosition.dx;
    if (dx < size.width / 3) {
      _onTapLeft();
    } else if (dx > size.width * 2 / 3) {
      _onTapRight();
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
      if (_currentIndex > 0) {
        _goDissolvePage(_currentIndex - 1);
      } else {
        _prevChapter();
      }
      return;
    }
    if (_currentIndex > 0) {
      _pageController.previousPage(
        duration: const Duration(milliseconds: 250),
        curve: Curves.easeOutCubic,
      );
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
      if (_currentIndex < _images.length - 1) {
        _goDissolvePage(_currentIndex + 1);
      } else {
        _nextChapter();
      }
      return;
    }
    if (_currentIndex < _images.length - 1) {
      _pageController.nextPage(
        duration: const Duration(milliseconds: 250),
        curve: Curves.easeOutCubic,
      );
    } else {
      _nextChapter();
    }
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
      backgroundColor: Colors.black,
      body: Stack(children: [_buildGallery(), _buildControls()]),
    );
  }

  Widget _buildGallery() {
    if (_isLoading) {
      return const Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            CircularProgressIndicator(),
            SizedBox(height: 16),
            Text('加载中...', style: TextStyle(color: Colors.white)),
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
            Text('加载失败: $_error', style: const TextStyle(color: Colors.white)),
            const SizedBox(height: 16),
            ElevatedButton(onPressed: _loadImages, child: const Text('重试')),
          ],
        ),
      );
    }

    if (_images.isEmpty) {
      return const Center(
        child: Text('暂无图片', style: TextStyle(color: Colors.white)),
      );
    }

    final Widget gallery = _isContinuousMode
        ? _buildContinuousGallery()
        : _isDissolveMode
        ? _buildDissolveGallery()
        : _buildPagedGallery();
    // 章节加载完成时淡入过渡
    // 外层 PageStorage 用每次加载重建的空桶，让 ScrollablePositionedList
    // initState 读 PageStorage 拿到 null，从第 0 页开始（不恢复历史偏移）
    return PageStorage(
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
  }

  /// 翻页模式：PhotoViewGallery 逐页翻页（横向=左右翻页，竖向=上下翻页）
  Widget _buildPagedGallery({Axis scrollDirection = Axis.horizontal}) {
    return GestureDetector(
      onTapUp: _handleTap,
      child: PhotoViewGallery.builder(
        scrollDirection: scrollDirection,
        scrollPhysics: const ClampingScrollPhysics(),
        builder: (context, index) {
          return PhotoViewGalleryPageOptions(
            imageProvider: _useLocal
                ? FileImage(File(_images[index]))
                : CachedNetworkImageProvider(_images[index]),
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
        backgroundDecoration: const BoxDecoration(color: Colors.black),
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

  /// 消散模式：逐页显示，换页时旧页淡出、新页淡入（交叉淡入淡出）
  Widget _buildDissolveGallery() {
    return GestureDetector(
      onTapUp: _handleTap,
      child: ColoredBox(
        color: Colors.black,
        child: AnimatedSwitcher(
          duration: const Duration(milliseconds: 600),
          switchInCurve: Curves.easeInOut,
          switchOutCurve: Curves.easeInOut,
          transitionBuilder: (child, anim) =>
              FadeTransition(opacity: anim, child: child),
          child: _buildDissolveImage(_currentIndex),
        ),
      ),
    );
  }

  /// 消散模式单页图（按 index 取 key，AnimatedSwitcher 据此触发交叉淡入淡出）
  Widget _buildDissolveImage(int index) {
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
        cacheWidth: dw,
        errorBuilder: (context, error, stackTrace) => _buildBrokenImage(index),
      );
    } else {
      image = CachedNetworkImage(
        imageUrl: _images[index],
        fit: BoxFit.contain,
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
    return SizedBox.expand(key: ValueKey(index), child: image);
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
    return CachedNetworkImage(
      key: imageKey,
      imageUrl: _images[index],
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
    return Text('${_currentIndex + 1} / ${_images.length}', style: style);
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
            // 底部栏
            Container(
              color: Colors.black87,
              padding: const EdgeInsets.all(16),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  // 页码滑块（拼页模式下不显示）
                  if (_images.isNotEmpty && !_isContinuousMode)
                    Slider(
                      value: _currentIndex.toDouble(),
                      min: 0,
                      max: (_images.length - 1).toDouble(),
                      onChanged: (value) {
                        setState(() {
                          _currentIndex = value.toInt();
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
                  // 页码和按钮
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                    children: [
                      TextButton.icon(
                        onPressed: _prevChapter,
                        icon: const Icon(
                          Icons.chevron_left,
                          color: Colors.white,
                        ),
                        label: const Text(
                          '上一话',
                          style: TextStyle(color: Colors.white),
                        ),
                      ),
                      _buildPageIndicator(),
                      TextButton.icon(
                        onPressed: _nextChapter,
                        icon: const Icon(
                          Icons.chevron_right,
                          color: Colors.white,
                        ),
                        label: const Text(
                          '下一话',
                          style: TextStyle(color: Colors.white),
                        ),
                      ),
                    ],
                  ),
                  // 目录按钮（右对齐，同图书阅读器）
                  Row(
                    children: [
                      const Expanded(child: SizedBox()),
                      TextButton.icon(
                        onPressed: _showToc,
                        icon: const Icon(
                          Icons.menu_book_rounded,
                          color: Colors.white,
                        ),
                        label: const Text(
                          '目录',
                          style: TextStyle(color: Colors.white),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
