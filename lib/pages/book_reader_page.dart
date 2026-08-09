import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:photo_view/photo_view.dart';
import 'package:photo_view/photo_view_gallery.dart';
import 'package:scrollable_positioned_list/scrollable_positioned_list.dart';

import '../models/book.dart';
import '../models/book_content.dart';
import '../models/bookshelf.dart';
import '../services/book_download_service.dart';
import '../services/book_paginator.dart';
import '../services/book_page_cache_service.dart';
import '../services/book_parser.dart';
import '../services/book_reading_progress_service.dart';
import '../services/bookshelf_service.dart';
import '../services/platform_service.dart';
import '../services/settings_service.dart';
import '../theme/jelly_theme.dart';
import '../widgets/book_page_curl.dart';
import 'book_prefetch_page.dart';

/// 图书阅读页：EPUB / MOBI / TXT / PDF app 内排版阅读；
/// 其余格式由 [open] 路由到外部应用。
/// 固定 TextPainter 度量分页翻页（不再支持连续滚动，不受阅读模式设置控制）。
class BookReaderPage extends StatefulWidget {
  final BookDownloadTask task;
  final BookPrefetchedData? prefetched;

  const BookReaderPage({super.key, required this.task, this.prefetched});

  /// 统一入口：epub/txt/mobi/azw/azw3 进排版阅读器，pdf 进 PDF 渲染页，
  /// 其余格式调系统外部应用打开。
  static Future<void> open(BuildContext context, BookDownloadTask task) async {
    final ext = (task.extension ?? 'epub').toLowerCase();
    if (ext == 'epub' ||
        ext == 'txt' ||
        ext == 'mobi' ||
        ext == 'azw' ||
        ext == 'azw3' ||
        ext == 'pdf') {
      await Navigator.push(
        context,
        MaterialPageRoute(builder: (_) => BookPrefetchPage(task: task)),
      );
      return;
    }
    if (task.localPath == null || !await File(task.localPath!).exists()) {
      if (!context.mounted) return;
      _toast(context, '文件不存在，请重新下载');
      return;
    }
    final ok = await PlatformService.openFile(task.localPath!, _mimeOf(ext));
    if (!ok) {
      if (!context.mounted) return;
      _toast(context, '未找到可打开此格式的应用');
    }
  }

  static void _toast(BuildContext context, String msg) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text(msg),
          duration: const Duration(seconds: 2),
          behavior: SnackBarBehavior.floating,
        ),
      );
  }

  static String _mimeOf(String ext) {
    switch (ext) {
      case 'pdf':
        return 'application/pdf';
      case 'mobi':
      case 'azw':
      case 'azw3':
        return 'application/x-mobipocket-ebook';
      case 'cbz':
        return 'application/vnd.comicbook+zip';
      case 'cbr':
        return 'application/vnd.comicbook-rar';
      case 'fb2':
        return 'application/x-fictionbook+xml';
      case 'docx':
        return 'application/vnd.openxmlformats-officedocument.wordprocessingml.document';
      case 'rtf':
        return 'application/rtf';
      case 'txt':
        return 'text/plain';
      default:
        return 'application/octet-stream';
    }
  }

  @override
  State<BookReaderPage> createState() => _BookReaderPageState();
}

/// 过渡页预计算好的分页结果，传给阅读器避免重复解析 / 分页。
class BookPrefetchedData {
  final BookContent content;
  final List<BookPage> pages;
  final Map<String, double> ratios;
  final String key;
  final String fingerprint;

  /// 未完成分页时的分页器实例；阅读器后台继续 stepInto 追加剩余页。
  /// null = 已分页完毕。
  final BookPaginator? paginator;

  const BookPrefetchedData({
    required this.content,
    required this.pages,
    required this.ratios,
    required this.key,
    required this.fingerprint,
    this.paginator,
  });
}

class _BookReaderPageState extends State<BookReaderPage> {
  BookContent? _content;
  bool _loading = true;
  String? _error;

  bool _showControls = false;
  // 上次已归位的状态书架，避免翻页重复调 BookshelfService
  String? _lastAppliedStatus;

  // 单击翻页判定：记录按下位置与时间，区分单击 / 长按选字 / 拖动翻页
  Offset? _tapDownPos;
  DateTime? _tapDownTime;

  // 排版参数（与 SettingsService 同步）
  late BookTypography _typo;

  // 翻页模式
  late final PageController _pageController;
  List<BookPage> _pages = const [];
  int _currentPage = 0;
  // 常驻 HUD（页码/进度）监听此 notifier，翻页时局部刷新，不重建 PageView
  final ValueNotifier<int> _currentPageNotifier = ValueNotifier(0);
  bool _paginating = false;
  int _paginateDone = 0;
  int _paginateTotal = 0;
  final Map<String, double> _imageRatios = {};
  String _paginateKey = '';
  String _contentFingerprint = '';

  // 流式分页：过渡页分到"够读"就进阅读器，剩余的在此后台继续。
  // 非 null 表示后台分页进行中；旋屏 / 参数变更 / dispose 会置 null 取消。
  BookPaginator? _ongoingPaginator;

  // 后台分页时续读定位：进入时续读 block 尚未分到页，待后台分页覆盖后自动跳转。
  // 仅在用户未手动翻页时跳一次，避免打扰已开始阅读的用户。
  int? _pendingResumeBlock;
  bool _userPaged = false;
  // 后台分页进度（底部细进度条用）
  int _bgPaginateDone = 0;
  int _bgPaginateTotal = 0;

  // 图片模式：全图书走图库（PhotoView 画廊 / 消散），跳过文本分页。
  // _currentPageNotifier 在图片模式下存当前图序号，复用 HUD。
  List<int> _imageBlockIndices = const []; // flatBlocks 中 ImageBlock 的索引
  bool _isImageMode = false;
  int _currentImageIndex = 0;
  PageController? _imagePageController;

  List<BookBlock> get _blocks => _content?.flatBlocks ?? [];
  List<int> get _chapterStarts => _content?.chapterStarts ?? [];

  @override
  void initState() {
    super.initState();
    _typo = _typoFromSettings();
    final pf = widget.prefetched;
    if (pf != null) {
      // 过渡页已解析 + 分页 + 缓存命中参数，直接复用，跳过 _load / _paginate
      _content = pf.content;
      _pages = pf.pages;
      _imageRatios.addAll(pf.ratios);
      _paginateKey = pf.key;
      _contentFingerprint = pf.fingerprint;
      _log(
        'reader进入 prefetched pages=${pf.pages.length} paginator=${pf.paginator != null} key=$_paginateKey',
      );
      _loading = false;
      _setupImageMode();
      // 续读位置：原由 _paginate 末尾跳转，此处直接按进度定位首页。
      // 大书续读靠后、过渡页未分到时：先定位到已分页末页，记下待定位 block，
      // 后台分页覆盖后续读块后自动跳转（仅一次，且仅当用户未手动翻页）。
      final flat = _content!.flatBlocks;
      final p = BookReadingProgressService().getProgress(widget.task.bookId);
      final startBlock = p == null ? 0 : p.blockIndex.clamp(0, flat.length - 1);
      final target = BookPaginator.pageIndexOf(_pages, startBlock);
      if (_pages.isNotEmpty && startBlock > _pages.last.firstBlockIndex) {
        _pendingResumeBlock = startBlock;
      }
      _currentPage = target;
      // 图片模式下 notifier 已由 _setupImageMode 置为当前图序号，勿覆盖
      if (!_isImageMode) _currentPageNotifier.value = target;
      _pageController = PageController(initialPage: target);
      // 过渡页可能只分了一部分就进来：后台继续补齐剩余页
      final pg = pf.paginator;
      if (pg != null && !pg.finished) {
        _ongoingPaginator = pg;
        _bgPaginateTotal = pg.blockCount;
        _bgPaginateDone = pg.currentBlockIndex;
        WidgetsBinding.instance.addPostFrameCallback(
          (_) => _continuePagination(),
        );
      }
    } else {
      _pageController = PageController();
      _load();
    }
    SettingsService().addListener(_onSettingsChanged);
    // 沉浸阅读：延后到路由转场动画结束再隐藏顶部状态栏（保留底部导航栏），
    // 避免系统栏切换与 MaterialPageRoute 转场叠加造成进入卡顿。
    Future.delayed(const Duration(milliseconds: 350), () {
      if (!mounted) return;
      SystemChrome.setEnabledSystemUIMode(
        SystemUiMode.manual,
        overlays: [SystemUiOverlay.bottom],
      );
    });
  }

  @override
  void dispose() {
    // 后台续分页未完：捕获 partial 状态 fire-and-forget 写缓存，下次断点续分页，
    // 不再从头重排。pages 的 block 皆来自 content.flatBlocks（主线程分页 / read
    // 主线程重建），identity 与 flatBlocks 一致，write idx 命中。
    final pg = _ongoingPaginator;
    if (pg != null &&
        !pg.finished &&
        _content != null &&
        _paginateKey.isNotEmpty) {
      final pages = List<BookPage>.of(_pages);
      final ratios = Map<String, double>.of(_imageRatios);
      final flat = _content!.flatBlocks;
      final key = _paginateKey;
      final bookId = widget.task.bookId;
      final snap = pg.snapshot;
      _log(
        '写分页缓存(partial,dispose) key=$key pages=${pages.length} resume=${snap.blockIndex}',
      );
      // 不 await：dispose 不可阻塞；引用已捕获，widget 销毁后仍有效
      BookPageCacheService.instance.write(
        bookId: bookId,
        key: key,
        pages: pages,
        ratios: ratios,
        flatBlocks: flat,
        partial: true,
        resumeBlockIndex: snap.blockIndex,
        cur: snap.cur,
        curFirst: snap.curFirst,
        remaining: snap.remaining,
      );
    }
    _ongoingPaginator = null; // 取消后台流式分页（循环见 null 即退出）
    SettingsService().removeListener(_onSettingsChanged);
    _pageController.dispose();
    _imagePageController?.dispose();
    _currentPageNotifier.dispose();
    // 离开阅读器：恢复状态栏（App 默认 edge-to-edge）
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    // 进度在阅读中已持久化但未 notify；退出时延后到帧末通知书架刷新进度徽标，
    // 避免在 widget tree 锁定期间（路由出栈）markNeedsBuild 崩溃。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      BookReadingProgressService().notifyProgressChanged();
    });
    super.dispose();
  }

  BookTypography _typoFromSettings([TextScaler? scaler, TextStyle? inherited]) {
    final s = SettingsService();
    return BookTypography(
      fontSize: s.bookFontSize,
      lineHeight: s.bookLineHeight,
      padding: s.bookHorizontalPadding,
      verticalPadding: s.bookVerticalPadding,
      fontFamily: s.bookFontFamilyName,
      // 祖先 DefaultTextStyle.style：渲染端 SelectableText/Text 会 merge 它，
      // 度量须同步 merge，否则 letterSpacing/fontWeight 等残留字段致 meas<col。
      inheritedStyle: inherited ?? const TextStyle(),
      // 系统字体缩放：渲染由 SelectableText 自动应用，度量须传入同一 TextScaler
      // 对象，否则度量与渲染缩放不一致（留白或溢出，见 BookTypography.textScaler）。
      textScaler: scaler ?? TextScaler.noScaling,
    );
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // initState 无 context，scaler/inherited 先默认；此处拿到 MediaQuery 后校正。
    // 用系统 TextScaler 原对象（非 scale(1.0) 重建），保证度量与渲染缩放一致。
    // inheritedStyle 取渲染端 defaultTextStyle（Scaffold 内 Material 注入的
    // theme.textTheme.bodyMedium），度量 merge 它以消除 letterSpacing 等残留字段
    // 差异（meas<col）。此处 context 在 Scaffold 外，DefaultTextStyle.of 可能不同源，
    // 故直接取 textTheme.bodyMedium 与渲染端对齐。
    final scaler = MediaQuery.textScalerOf(context);
    final inherited =
        Theme.of(context).textTheme.bodyMedium ?? const TextStyle();
    if (_typo.textScaler.scale(1.0) != scaler.scale(1.0) ||
        _typo.inheritedStyle != inherited) {
      _typo = _typoFromSettings(scaler, inherited);
    }
  }

  void _onSettingsChanged() {
    if (!mounted) return;
    final newTypo = _typoFromSettings(_typo.textScaler, _typo.inheritedStyle);
    if (newTypo.fontSize != _typo.fontSize ||
        newTypo.lineHeight != _typo.lineHeight ||
        newTypo.padding != _typo.padding ||
        newTypo.verticalPadding != _typo.verticalPadding ||
        newTypo.fontFamily != _typo.fontFamily) {
      _typo = newTypo;
    }
    setState(() {});
    // 仿真切回翻页模式后 PageView 重建，需把控制器同步到当前页
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      if (_isImageMode) {
        final c = _imagePageController;
        if (c != null && c.hasClients) c.jumpToPage(_currentImageIndex);
        return;
      }
      if (SettingsService().bookReadingMode == BookReadingMode.pageTurn &&
          _pageController.hasClients) {
        _pageController.jumpToPage(_currentPage);
      }
    });
  }

  Future<void> _load() async {
    final task = widget.task;
    final path = task.localPath;
    if (path == null || !await File(path).exists()) {
      if (mounted) {
        setState(() {
          _loading = false;
          _error = '文件不存在，请重新下载';
        });
      }
      return;
    }
    try {
      final ext = (task.extension ?? 'epub').toLowerCase();
      // 解析 + 图片宽高比合并到同一 isolate，省 images 一次跨 isolate 深拷贝
      BookContent content;
      if (ext == 'txt') {
        content = await compute(BookParser.parseTxt, File(path));
      } else if (ext == 'mobi' || ext == 'azw' || ext == 'azw3') {
        final r = await compute(BookParser.parseMobiWithRatios, File(path));
        content = r.content;
        _imageRatios.addAll(r.ratios);
      } else {
        final r = await compute(BookParser.parseEpubWithRatios, File(path));
        content = r.content;
        _imageRatios.addAll(r.ratios);
      }
      if (!mounted) return;
      setState(() {
        _content = content;
        _loading = false;
      });
      _contentFingerprint = BookPageCacheService.contentFingerprint(content);
      _setupImageMode();
      _restoreProgress();
    } catch (e) {
      if (mounted) {
        setState(() {
          _loading = false;
          _error = '$e';
        });
      }
    }
  }

  void _restoreProgress() {
    // 翻页模式：续读位置在 _paginate 末尾按 preserveBlockIndex 跳转
  }

  /// 分页缓存键：视口尺寸 + 排版参数 + bookId + 内容指纹。_buildPaged 与 _paginate
  /// 及过渡页 / 缓存服务共用同一格式（[BookPageCacheService.keyOf]），确保判等一致，
  /// 避免字号变化或内容更新后用过期分页渲染导致底部溢出。
  String _paginateKeyOf(double vpW, double vpH) => BookPageCacheService.keyOf(
    vpW: vpW,
    vpH: vpH,
    typo: _typo,
    bookId: widget.task.bookId,
    fingerprint: _contentFingerprint,
  );

  /// pageTurn 模式：按当前视口与排版参数分页（章间让出 UI 线程，显示进度）。
  /// [preserveBlockIndex] 为重排前所在 block，重排后跳到包含它的页。
  void _log(String msg) {
    if (kDebugMode) print('[BookReader] $msg');
  }

  /// 后台流式分页：过渡页分到"够读"就进阅读器，剩余的在此继续切成页追加进 _pages。
  /// 用户阅读不受影响（PageView 的 itemCount 随追加增长，当前页不变）。
  /// 旋屏 / 参数变更 / dispose 会置 _ongoingPaginator=null，循环即退出。
  Future<void> _continuePagination() async {
    final paginator = _ongoingPaginator;
    if (paginator == null) return;
    while (!paginator.finished && _ongoingPaginator == paginator && mounted) {
      paginator.stepInto(_pages, chunk: 12);
      _bgPaginateDone = paginator.currentBlockIndex;
      if (!mounted || _ongoingPaginator != paginator) return;
      // 续读定位：后台分页已覆盖续读 block 且用户未手动翻页 -> 跳转一次
      final pending = _pendingResumeBlock;
      if (pending != null &&
          !_userPaged &&
          paginator.currentBlockIndex > pending) {
        _pendingResumeBlock = null;
        final newTarget = BookPaginator.pageIndexOf(_pages, pending);
        if (newTarget != _currentPage) {
          _currentPage = newTarget;
          _currentPageNotifier.value = newTarget;
          if (_pageController.hasClients) _pageController.jumpToPage(newTarget);
        }
      }
      setState(() {});
      SchedulerBinding.instance.scheduleFrame();
      await SchedulerBinding.instance.endOfFrame;
    }
    // 被取消（旋屏 / 参数变更 / dispose）则不写缓存
    if (!paginator.finished || _ongoingPaginator != paginator) return;
    _ongoingPaginator = null;
    if (mounted) setState(() {}); // 清除底部进度条
    await BookPageCacheService.instance.write(
      bookId: widget.task.bookId,
      key: _paginateKey,
      pages: _pages,
      ratios: _imageRatios,
      flatBlocks: paginator.blocks,
    );
    _log('写分页缓存(后台完成) key=$_paginateKey pages=${_pages.length}');
  }

  /// 调参 / 旋屏重排：首批分到当前阅读位置即显示，剩余页后台增量补齐
  /// （[_continuePagination]），避免全本排完才能读。复用后台流式分页机制。
  Future<void> _repaginateBackground({
    required double vpW,
    required double vpH,
    required int preserveBlockIndex,
  }) async {
    final content = _content;
    if (content == null) return;
    final key = _paginateKeyOf(vpW, vpH);
    if (key == _paginateKey && _pages.isNotEmpty) return;
    _ongoingPaginator = null; // 取消旧后台分页
    _pendingResumeBlock = null; // 调参重排定位由首批直接完成，无需续读跳转
    _paginateKey = key;
    final typo = _typo;
    final allBlocks = content.flatBlocks;
    final starts = content.chapterStarts;
    final totalChapters = starts.length;
    final paginator = BookPaginator(
      blocks: allBlocks,
      viewportWidth: vpW,
      viewportHeight: vpH,
      typo: typo,
      imageAspectRatios: _imageRatios,
      chapterStarts: starts.toSet(),
    );
    setState(() {
      _paginating = true;
      _paginateDone = 0;
      _paginateTotal = totalChapters;
    });
    final pages = <BookPage>[];
    final preserve = preserveBlockIndex.clamp(0, allBlocks.length - 1);
    var chapterDone = 0;
    // 首批：增量分到覆盖当前阅读位置（preserve），每批让出 UI
    while (!paginator.finished && paginator.currentBlockIndex <= preserve) {
      paginator.stepInto(pages, chunk: 12);
      final bi = paginator.currentBlockIndex;
      while (chapterDone < totalChapters && starts[chapterDone] < bi) {
        chapterDone++;
      }
      if (mounted) setState(() => _paginateDone = chapterDone);
      SchedulerBinding.instance.scheduleFrame();
      await SchedulerBinding.instance.endOfFrame;
      if (!mounted) return;
    }
    if (!mounted) return;
    final target = BookPaginator.pageIndexOf(pages, preserve);
    setState(() {
      _pages = pages;
      _paginating = false;
      _currentPage = target;
      _ongoingPaginator = paginator;
      _bgPaginateTotal = paginator.blockCount;
      _bgPaginateDone = paginator.currentBlockIndex;
    });
    _currentPageNotifier.value = target;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && _pageController.hasClients) {
        _pageController.jumpToPage(target);
      }
    });
    _log('重排首批 ${pages.length} 页 -> 定位 block $preserve 页 $target，后台补齐剩余');
    // 后台增量补齐剩余页（底部进度条，不打扰阅读）
    _continuePagination();
  }

  void _onPointerDown(PointerDownEvent e) {
    _tapDownPos = e.position;
    _tapDownTime = DateTime.now();
  }

  void _onPointerUp(PointerUpEvent e) {
    // 控件栏显示时，点击交给控件层处理（按钮 / 中间空白关闭），不翻页
    if (_showControls) return;
    final pos = _tapDownPos;
    final t = _tapDownTime;
    _tapDownPos = null;
    _tapDownTime = null;
    if (pos == null || t == null) return;
    final dist = (e.position - pos).distance;
    final dt = DateTime.now().difference(t).inMilliseconds;
    // 长按选字（>350ms）或拖动翻页（位移大）交给下层，仅短按单击才翻页
    if (dist > 18 || dt > 350) return;
    final w = MediaQuery.sizeOf(context).width;
    final dx = e.position.dx;
    if (dx < w / 3) {
      _onTapLeft();
    } else if (dx > w * 2 / 3) {
      _onTapRight();
    } else {
      _toggleControls();
    }
  }

  void _toggleControls() => setState(() => _showControls = !_showControls);

  void _onTapLeft() {
    if (_currentPage > 0) {
      _pageController.previousPage(
        duration: const Duration(milliseconds: 250),
        curve: Curves.easeOutCubic,
      );
    }
  }

  void _onTapRight() {
    if (_currentPage < _pages.length - 1) {
      _pageController.nextPage(
        duration: const Duration(milliseconds: 250),
        curve: Curves.easeOutCubic,
      );
    }
  }

  void _goChapter(int chapterIndex) {
    if (chapterIndex < 0 || chapterIndex >= _chapterStarts.length) return;
    final blockIndex = _chapterStarts[chapterIndex];
    if (_isImageMode) {
      final imgIdx = _imageIndexOfBlock(blockIndex, clamp: true);
      if (imgIdx >= 0) _imageGoto(imgIdx);
      setState(() => _showControls = false);
      return;
    }
    final page = BookPaginator.pageIndexOf(_pages, blockIndex);
    // 仿真模式无 PageView，_pageController 未挂载，直接切 _currentPage；
    // pageTurn 模式经 PageView 滚动（onPageChanged 会同步 _currentPage 与进度）。
    if (SettingsService().bookReadingMode == BookReadingMode.simulation) {
      _turnTo(page);
    } else if (_pageController.hasClients) {
      _pageController.jumpToPage(page);
    }
    setState(() => _showControls = false);
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final bgColor = isDark
        ? JellyTheme.backgroundDark
        : JellyTheme.backgroundLight;
    final textColor = isDark
        ? Colors.white.withValues(alpha: 0.92)
        : JellyTheme.textPrimaryLight;
    return Scaffold(
      backgroundColor: bgColor,
      body: Stack(
        children: [
          _buildBody(isDark, textColor, bgColor),
          _buildHud(isDark),
          _buildControls(isDark, textColor),
        ],
      ),
    );
  }

  Widget _buildBody(bool isDark, Color textColor, Color bgColor) {
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const Icon(
                Icons.error_outline,
                size: 48,
                color: JellyTheme.error,
              ),
              const SizedBox(height: 16),
              Text(
                '打开失败：$_error',
                textAlign: TextAlign.center,
                style: TextStyle(color: textColor),
              ),
              const SizedBox(height: 16),
              if (widget.task.localPath != null)
                TextButton.icon(
                  onPressed: () async {
                    final ok = await PlatformService.openFile(
                      widget.task.localPath!,
                      BookReaderPage._mimeOf(
                        (widget.task.extension ?? 'epub').toLowerCase(),
                      ),
                    );
                    if (!ok && mounted) {
                      BookReaderPage._toast(context, '未找到可打开此格式的应用');
                    }
                  },
                  icon: const Icon(Icons.open_in_new),
                  label: const Text('用其他应用打开'),
                ),
            ],
          ),
        ),
      );
    }
    if (_content == null || _blocks.isEmpty) {
      return Center(
        child: Text('暂无内容', style: TextStyle(color: textColor)),
      );
    }
    if (_isImageMode && _imageBlockIndices.isNotEmpty) {
      return _buildImageGallery();
    }
    return _buildPaged(textColor, bgColor);
  }

  // ---------------- pageTurn 模式 ----------------

  Widget _buildPaged(Color textColor, Color bgColor) {
    return SafeArea(
      top: false,
      bottom: false,
      child: LayoutBuilder(
        builder: (context, constraints) {
          final vpW = constraints.maxWidth;
          final vpH = constraints.maxHeight;
          // 仿真背景图需铺满全屏（含原状态栏区），故上下不交由 SafeArea，
          // 改为手动按安全区给文字留白；分页用扣掉安全区后的高度，与原一致。
          final safeTop = MediaQuery.paddingOf(context).top;
          final safeBottom = MediaQuery.paddingOf(context).bottom;
          final textVpH = vpH - safeTop - safeBottom;
          // 视口或排版参数变化 -> 重新分页（保留当前 block）
          final key = _paginateKeyOf(vpW, textVpH);
          final needRepaginate = key != _paginateKey;
          _log(
            'reader视口 vpW=$vpW textVpH=$textVpH key=$key oldKey=$_paginateKey needRepaginate=$needRepaginate pages=${_pages.length} ongoing=${_ongoingPaginator != null}',
          );
          if (needRepaginate && !_paginating) {
            // 视口 / 参数变化：后台重排，首批到当前页即显示，剩余增量补齐
            WidgetsBinding.instance.addPostFrameCallback((_) {
              final preserve = _pages.isEmpty
                  ? (BookReadingProgressService()
                            .getProgress(widget.task.bookId)
                            ?.blockIndex ??
                        0)
                  : _pages[_currentPage.clamp(0, _pages.length - 1)]
                        .firstBlockIndex;
              _repaginateBackground(
                vpW: vpW,
                vpH: textVpH,
                preserveBlockIndex: preserve,
              );
            });
          }
          // 待重排时旧分页已按旧字号度量，直接显示占位，避免用新字号渲染溢出底部
          if (_paginating || _pages.isEmpty || needRepaginate) {
            return _buildPaginatingView(textColor);
          }
          final contentWidth = vpW - _typo.padding * 2;
          // 正文就绪后淡入，消除 loading -> 排版 -> 正文 的硬切（参照漫画阅读器）
          // key 绑定分页参数：重排（视口/字号变化）时 key 变化重新淡入，
          // 稳定时保持 1.0 不重跑
          return Stack(
            fit: StackFit.expand,
            children: [
              TweenAnimationBuilder<double>(
                key: ValueKey('fade_$_paginateKey'),
                tween: Tween(begin: 0.0, end: 1.0),
                duration: const Duration(milliseconds: 250),
                curve: Curves.easeOut,
                builder: (context, v, child) =>
                    Opacity(opacity: v, child: child),
                child: _buildReaderContent(
                  textColor,
                  contentWidth,
                  safeTop,
                  safeBottom,
                ),
              ),
              // 后台流式分页进行中：底部细进度条，不打扰阅读
              if (_ongoingPaginator != null)
                Positioned(
                  left: 0,
                  right: 0,
                  bottom: safeBottom,
                  child: LinearProgressIndicator(
                    value: _bgPaginateTotal > 0
                        ? _bgPaginateDone / _bgPaginateTotal
                        : null,
                    minHeight: 2,
                    backgroundColor: Colors.transparent,
                    valueColor: AlwaysStoppedAnimation<Color>(
                      textColor.withValues(alpha: 0.5),
                    ),
                  ),
                ),
            ],
          );
        },
      ),
    );
  }

  Widget _buildReaderContent(
    Color textColor,
    double contentWidth,
    double safeTop,
    double safeBottom,
  ) {
    if (SettingsService().bookReadingMode == BookReadingMode.simulation) {
      return _buildSimulation(textColor, contentWidth, safeTop, safeBottom);
    }
    return Listener(
      behavior: HitTestBehavior.translucent,
      onPointerDown: _onPointerDown,
      onPointerUp: _onPointerUp,
      child: PageView.builder(
        controller: _pageController,
        physics: const ClampingScrollPhysics(),
        itemCount: _pages.length,
        onPageChanged: (i) {
          _currentPage = i;
          _currentPageNotifier.value = i;
          _userPaged = true; // 用户手动翻页，取消后台续读自动跳转
          BookReadingProgressService().recordBlock(
            widget.task.bookId,
            _pages[i].firstBlockIndex,
            i,
            _pages.length,
          );
          _applyReadingStatus();
        },
        itemBuilder: (context, index) =>
            _buildPageView(index, textColor, contentWidth, safeTop, safeBottom),
      ),
    );
  }

  Widget _buildSimulation(
    Color textColor,
    double contentWidth,
    double safeTop,
    double safeBottom,
  ) {
    return BookPageCurl(
      // 翻起页自带背景图底：栅格化出"背景图+文字"的不透明页，卷曲时文字附在
      // 背景图纸面上；nextPage/prevPage 保持透明，翻页时露出底层背景图。
      page: Stack(
        fit: StackFit.expand,
        children: [
          Image.asset(
            'assets/images/reader_backgroud.jpg',
            fit: BoxFit.cover,
            width: double.infinity,
            height: double.infinity,
          ),
          _buildPageView(
            _currentPage,
            textColor,
            contentWidth,
            safeTop,
            safeBottom,
          ),
        ],
      ),
      nextPage: _currentPage < _pages.length - 1
          ? _buildPageView(
              _currentPage + 1,
              textColor,
              contentWidth,
              safeTop,
              safeBottom,
            )
          : null,
      prevPage: _currentPage > 0
          ? _buildPageView(
              _currentPage - 1,
              textColor,
              contentWidth,
              safeTop,
              safeBottom,
            )
          : null,
      background: Image.asset(
        'assets/images/reader_backgroud.jpg',
        fit: BoxFit.cover,
        width: double.infinity,
        height: double.infinity,
      ),
      canNext: _currentPage < _pages.length - 1,
      canPrev: _currentPage > 0,
      onTurnNext: () => _turnTo(_currentPage + 1),
      onTurnPrev: () => _turnTo(_currentPage - 1),
      onTapCenter: _toggleControls,
    );
  }

  Widget _buildPageView(
    int index,
    Color textColor,
    double contentWidth,
    double safeTop,
    double safeBottom,
  ) {
    final entries = _pages[index].entries;
    return Padding(
      padding: EdgeInsets.fromLTRB(
        _typo.padding,
        safeTop + _typo.verticalPadding,
        _typo.padding,
        safeBottom + _typo.verticalPadding,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (var i = 0; i < entries.length; i++) ...[
            _buildEntry(entries[i], textColor, contentWidth),
            if (i < entries.length - 1) SizedBox(height: _typo.blockSpacing),
          ],
        ],
      ),
    );
  }

  void _turnTo(int index) {
    if (index < 0 || index >= _pages.length) return;
    _userPaged = true; // 仿真翻页也算用户操作，取消后台续读自动跳转
    setState(() => _currentPage = index);
    _currentPageNotifier.value = index;
    BookReadingProgressService().recordBlock(
      widget.task.bookId,
      _pages[index].firstBlockIndex,
      index,
      _pages.length,
    );
    _applyReadingStatus();
  }

  /// 按当前进度把书归位到"正在读"/"已读完"书架（幂等，带状态缓存避免频繁调用）。
  void _applyReadingStatus() {
    if (_isImageMode) {
      if (_imageBlockIndices.isEmpty) return;
      final finished = _currentImageIndex + 1 >= _imageBlockIndices.length;
      final target = finished
          ? BookshelfService.presetFinished
          : BookshelfService.presetReading;
      if (_lastAppliedStatus == target) return;
      _lastAppliedStatus = target;
      final t = widget.task;
      BookshelfService().moveBetweenStatusShelves(
        bookId: t.bookId,
        type: BookshelfItemType.book,
        toShelf: target,
        meta: jsonEncode(
          Book(
            id: t.bookId,
            hash: t.hash,
            title: t.title,
            author: t.author,
            cover: t.cover,
            extension: t.extension,
          ).toJson(),
        ),
      );
      return;
    }
    if (_pages.isEmpty) return;
    final finished = _currentPage + 1 >= _pages.length;
    final target = finished
        ? BookshelfService.presetFinished
        : BookshelfService.presetReading;
    if (_lastAppliedStatus == target) return;
    _lastAppliedStatus = target;
    final t = widget.task;
    BookshelfService().moveBetweenStatusShelves(
      bookId: t.bookId,
      type: BookshelfItemType.book,
      toShelf: target,
      meta: jsonEncode(
        Book(
          id: t.bookId,
          hash: t.hash,
          title: t.title,
          author: t.author,
          cover: t.cover,
          extension: t.extension,
        ).toJson(),
      ),
    );
  }

  // ---------------- 图片模式 ----------------

  /// 统计图片块并判定是否自动进入图片模式。
  /// 启发式（用户指定）：图片数 >= 10 且 有效图片占比 >= 90%。
  /// 占比分母剔除短文本块（trim 后长度 <= 20，如 "Page-N" 导航标签），
  /// 让夹带页码标签的绘本仍能识别为图片书。仅统计已预载字节的图片，
  /// PDF 等懒加载场景（images 为空、走 imageLoader）不进图片模式。
  void _setupImageMode() {
    final content = _content;
    final blocks = content?.flatBlocks ?? const [];
    _imageBlockIndices = const [];
    if (blocks.isEmpty || content == null) return;
    final indices = <int>[];
    // PDF 等懒加载场景：images 初始为空，每页都是 ImageBlock，直接计为图片页。
    final lazy = content.imageLoader != null;
    var imageCount = 0;
    var shortTextCount = 0;
    for (var i = 0; i < blocks.length; i++) {
      final b = blocks[i];
      if (b is ImageBlock) {
        if (lazy || content.images[b.imageKey] != null) {
          imageCount++;
          indices.add(i);
        }
      } else if (b is ParagraphBlock) {
        if (b.text.trim().length <= 20) shortTextCount++;
      } else if (b is HeadingBlock) {
        if (b.text.trim().length <= 20) shortTextCount++;
      }
    }
    _imageBlockIndices = indices;
    if (lazy) {
      // PDF：每页即图，默认进图片模式（消散/画廊按需光栅化 + 预载相邻页）。
      _isImageMode = imageCount > 0;
    } else if (imageCount >= 10) {
      final effectiveTotal = blocks.length - shortTextCount;
      if (effectiveTotal > 0 && imageCount / effectiveTotal >= 0.9) {
        _isImageMode = true;
      }
    }
    if (_isImageMode && _imageBlockIndices.isNotEmpty) {
      // 续读定位：按保存的 blockIndex 找最近图片
      final p = BookReadingProgressService().getProgress(widget.task.bookId);
      final startBlock = p == null
          ? 0
          : p.blockIndex.clamp(0, blocks.length - 1);
      _currentImageIndex = _imageIndexOfBlock(
        startBlock,
        clamp: true,
      ).clamp(0, _imageBlockIndices.length - 1);
      _imagePageController = PageController(initialPage: _currentImageIndex);
      _currentPageNotifier.value = _currentImageIndex;
      if (lazy) {
        // 首屏预载相邻页（post-frame，待 context 就绪）
        WidgetsBinding.instance.addPostFrameCallback(
          (_) => _preloadAdjacentImages(_currentImageIndex),
        );
      }
    }
  }

  /// 找 blockIndex 对应的图片序号：精确命中或首个 > blockIndex 的图片；
  /// [clamp]=true 时若后面没有图片则回退到最后一张（续读 / 跳章定位用）。
  int _imageIndexOfBlock(int blockIndex, {bool clamp = false}) {
    final indices = _imageBlockIndices;
    if (indices.isEmpty) return -1;
    for (var i = 0; i < indices.length; i++) {
      if (indices[i] == blockIndex) return i;
      if (indices[i] > blockIndex) return i;
    }
    return clamp ? indices.length - 1 : -1;
  }

  Uint8List? _imageBytesAt(int index) {
    if (index < 0 || index >= _imageBlockIndices.length) return null;
    final block = _blocks[_imageBlockIndices[index]];
    if (block is! ImageBlock) return null;
    return _content?.images[block.imageKey];
  }

  /// PDF 光栅化目标宽（物理像素）：屏宽 × dpr，clamp 上限控内存。
  /// 消散 / 画廊 / 预载共用同一值，保证 ImageProvider 缓存键一致。
  double get _pdfTargetWidth {
    final w = MediaQuery.sizeOf(context).width;
    final dpr = MediaQuery.devicePixelRatioOf(context);
    return (w * dpr).clamp(800.0, 2400.0);
  }

  /// 预载相邻页（PDF 懒加载）：把 index±1 经 precacheImage 提前光栅化+解码
  /// 进 Flutter 图片缓存，翻页时 Image 命中缓存首帧即出，消散交叉淡入无空白闪烁。
  void _preloadAdjacentImages(int index) {
    final loader = _content?.imageLoader;
    if (loader == null || _imageBlockIndices.isEmpty || !mounted) return;
    final w = _pdfTargetWidth;
    for (final delta in const [1, -1]) {
      final i = index + delta;
      if (i < 0 || i >= _imageBlockIndices.length) continue;
      final block = _blocks[_imageBlockIndices[i]];
      if (block is! ImageBlock) continue;
      precacheImage(_PdfPageImageProvider(block.imageKey, w, loader), context);
    }
  }

  /// 图片 / 文本模式互切。切回文本时按当前图片 block 定位到对应文本页；
  /// 切到图片时按当前页首 block 定位到最近图片。
  void _toggleImageMode() {
    if (_imageBlockIndices.isEmpty) return;
    final wasImageMode = _isImageMode;
    setState(() {
      _isImageMode = !_isImageMode;
      _showControls = false;
      if (wasImageMode) {
        final imgIdx = _currentImageIndex.clamp(
          0,
          _imageBlockIndices.length - 1,
        );
        final blockIndex = _imageBlockIndices[imgIdx];
        final page = BookPaginator.pageIndexOf(_pages, blockIndex);
        _currentPage = _pages.isEmpty ? 0 : page.clamp(0, _pages.length - 1);
        _currentPageNotifier.value = _currentPage;
        _imagePageController?.dispose();
        _imagePageController = null;
        if (SettingsService().bookReadingMode != BookReadingMode.simulation) {
          // pageTurn 模式 PageView 在图片模式期间未挂载，重建控制器以 initialPage 定位
          _pageController.dispose();
          _pageController = PageController(initialPage: _currentPage);
        }
      } else {
        final startBlock = _pages.isEmpty
            ? 0
            : _pages[_currentPage.clamp(0, _pages.length - 1)].firstBlockIndex;
        _currentImageIndex = _imageIndexOfBlock(
          startBlock,
          clamp: true,
        ).clamp(0, _imageBlockIndices.length - 1);
        _imagePageController = PageController(initialPage: _currentImageIndex);
        _currentPageNotifier.value = _currentImageIndex;
      }
    });
    _applyReadingStatus();
  }

  void _handleImageTap(TapUpDetails details) {
    if (_showControls) {
      _toggleControls();
      return;
    }
    final w = MediaQuery.sizeOf(context).width;
    final dx = details.globalPosition.dx;
    if (dx < w / 3) {
      _imagePrev();
    } else if (dx > w * 2 / 3) {
      _imageNext();
    } else {
      _toggleControls();
    }
  }

  void _imageGoto(int index) {
    if (index < 0 || index >= _imageBlockIndices.length) return;
    setState(() {
      _currentImageIndex = index;
      _currentPageNotifier.value = index;
    });
    final c = _imagePageController;
    if (c != null && c.hasClients) c.jumpToPage(index);
    _recordImageProgress();
    _applyReadingStatus();
    _preloadAdjacentImages(index);
  }

  void _imageNext() {
    final c = _imagePageController;
    if (c == null || !c.hasClients) {
      _imageGoto(_currentImageIndex + 1); // 控制器未挂载（如刚切模式）回退瞬切
      return;
    }
    if (_currentImageIndex < _imageBlockIndices.length - 1) {
      c.nextPage(
        duration: const Duration(milliseconds: 250),
        curve: Curves.easeOutCubic,
      );
    }
    // 到末页停住：图片模式为全书图片，无「下一话」可切。
  }

  void _imagePrev() {
    final c = _imagePageController;
    if (c == null || !c.hasClients) {
      _imageGoto(_currentImageIndex - 1);
      return;
    }
    if (_currentImageIndex > 0) {
      c.previousPage(
        duration: const Duration(milliseconds: 250),
        curve: Curves.easeOutCubic,
      );
    }
  }

  void _recordImageProgress() {
    if (_imageBlockIndices.isEmpty) return;
    final idx = _currentImageIndex.clamp(0, _imageBlockIndices.length - 1);
    BookReadingProgressService().recordBlock(
      widget.task.bookId,
      _imageBlockIndices[idx],
      idx,
      _imageBlockIndices.length,
    );
  }

  Widget _buildImageGallery() {
    // 仿真模式 -> 消散（交叉淡入淡出）；其余 -> PhotoView 画廊（左右翻页 + 双指缩放）
    if (SettingsService().bookReadingMode == BookReadingMode.simulation) {
      return _buildImageDissolve();
    }
    return _buildImagePhotoGallery();
  }

  Widget _buildImagePhotoGallery() {
    _imagePageController ??= PageController(initialPage: _currentImageIndex);
    return GestureDetector(
      onTapUp: _handleImageTap,
      child: PhotoViewGallery.builder(
        scrollPhysics: const ClampingScrollPhysics(),
        pageController: _imagePageController,
        itemCount: _imageBlockIndices.length,
        builder: (context, index) {
          final loader = _content?.imageLoader;
          final ImageProvider provider;
          if (loader != null) {
            // PDF 懒加载：经 ImageProvider 按需光栅化（避免 MemoryImage 空指针崩溃）
            final block = _blocks[_imageBlockIndices[index]] as ImageBlock;
            provider = _PdfPageImageProvider(
              block.imageKey,
              _pdfTargetWidth,
              loader,
            );
          } else {
            provider = MemoryImage(_imageBytesAt(index)!);
          }
          return PhotoViewGalleryPageOptions(
            imageProvider: provider,
            initialScale: PhotoViewComputedScale.contained,
            minScale: PhotoViewComputedScale.contained,
            maxScale: PhotoViewComputedScale.covered * 2,
            errorBuilder: (context, error, stackTrace) => Center(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  const Icon(Icons.broken_image, size: 48, color: Colors.grey),
                  const SizedBox(height: 8),
                  Text(
                    '第 ${index + 1} 张加载失败',
                    style: const TextStyle(color: Colors.grey),
                  ),
                ],
              ),
            ),
          );
        },
        loadingBuilder: (context, event) => const Center(
          child: SizedBox(
            width: 30,
            height: 30,
            child: CircularProgressIndicator(),
          ),
        ),
        backgroundDecoration: const BoxDecoration(color: Colors.black),
        onPageChanged: (i) {
          _currentImageIndex = i;
          _currentPageNotifier.value = i;
          _recordImageProgress();
          _applyReadingStatus();
          _preloadAdjacentImages(i);
        },
      ),
    );
  }

  Widget _buildImageDissolve() {
    return GestureDetector(
      onTapUp: _handleImageTap,
      child: ColoredBox(
        color: Colors.black,
        child: AnimatedSwitcher(
          duration: const Duration(milliseconds: 600),
          switchInCurve: Curves.easeInOut,
          switchOutCurve: Curves.easeInOut,
          transitionBuilder: (child, anim) =>
              FadeTransition(opacity: anim, child: child),
          child: _buildImageDissolvePage(_currentImageIndex),
        ),
      ),
    );
  }

  Widget _buildImageDissolvePage(int index) {
    if (index < 0 || index >= _imageBlockIndices.length) {
      return const SizedBox.shrink();
    }
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final loader = _content?.imageLoader;
    if (loader != null) {
      // PDF 懒加载：经 ImageProvider 走 Flutter 图片缓存；夜间反色（同文本模式）
      final block = _blocks[_imageBlockIndices[index]];
      if (block is! ImageBlock) return const SizedBox.shrink();
      return SizedBox.expand(
        key: ValueKey(index),
        child: Image(
          image: _PdfPageImageProvider(block.imageKey, _pdfTargetWidth, loader),
          fit: BoxFit.contain,
          gaplessPlayback: true,
          color: isDark ? Colors.white : null,
          colorBlendMode: isDark ? BlendMode.difference : null,
          loadingBuilder: (context, child, loadingProgress) {
            if (loadingProgress == null) return child;
            return const Center(child: CircularProgressIndicator());
          },
        ),
      );
    }
    final bytes = _imageBytesAt(index);
    if (bytes == null) {
      return SizedBox.expand(
        key: ValueKey(index),
        child: const Center(child: CircularProgressIndicator()),
      );
    }
    return SizedBox.expand(
      key: ValueKey(index),
      child: Image.memory(bytes, fit: BoxFit.contain, gaplessPlayback: true),
    );
  }

  Widget _buildPaginatingView(Color textColor) {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const CircularProgressIndicator(),
          const SizedBox(height: 16),
          Text(
            _paginateTotal > 0
                ? '排版中 $_paginateDone/$_paginateTotal 章'
                : '排版中...',
            style: TextStyle(color: textColor),
          ),
        ],
      ),
    );
  }

  // ---------------- 块渲染（两模式共用） ----------------

  Widget _buildEntry(PageEntry entry, Color textColor, double contentWidth) {
    final block = entry.block;
    if (block is ParagraphBlock) {
      final text = entry.partialText ?? block.text;
      return SelectableText(
        text,
        style: _typo.paragraphStyle().copyWith(color: textColor),
        strutStyle: _typo.paragraphStrut,
        textHeightBehavior: _typo.textHeightBehavior,
      );
    }
    if (block is HeadingBlock) {
      final text = entry.partialText ?? block.text;
      return Padding(
        padding: const EdgeInsets.only(top: 4),
        child: Text(
          text,
          style: _typo.headingStyle(block.level).copyWith(color: textColor),
          strutStyle: _typo.headingStrut(block.level),
          textHeightBehavior: _typo.textHeightBehavior,
        ),
      );
    }
    if (block is ImageBlock) {
      final bytes = _content?.images[block.imageKey];
      if (bytes == null) {
        // PDF 等懒加载场景：images 未预载，按需经 imageLoader 光栅化
        final loader = _content?.imageLoader;
        if (loader != null) {
          return Flexible(
            child: _PdfPageImage(
              imageKey: block.imageKey,
              contentWidth: contentWidth,
              loader: loader,
              onLoaded: (k, b) => _content?.images[k] = b,
            ),
          );
        }
        return const SizedBox.shrink();
      }
      final isDark = Theme.of(context).brightness == Brightness.dark;
      final dpr = MediaQuery.devicePixelRatioOf(context);
      return Flexible(
        child: Image.memory(
          bytes,
          width: contentWidth,
          cacheWidth: (contentWidth * dpr).round(),
          fit: BoxFit.contain,
          gaplessPlayback: true,
          color: isDark ? Colors.white : null,
          colorBlendMode: isDark ? BlendMode.difference : null,
        ),
      );
    }
    if (block is DividerBlock) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 4),
        child: Divider(height: 1),
      );
    }
    return const SizedBox.shrink();
  }

  // ---------------- 常驻 HUD（时间 / 页码 / 进度） ----------------

  Widget _buildHud(bool isDark) {
    final color = (isDark ? Colors.white : Colors.black).withValues(
      alpha: 0.45,
    );
    final style = TextStyle(fontSize: 11, color: color);
    final hPad = _typo.padding; // 左右边距
    final vPad = _typo.verticalPadding; // 上下边距
    // HUD 上下跟随垂直边距，并比正文留 20px 间距，避免压到首行/末行。
    // vPad < 20 时（上下边距调小）-20 会进入安全区：顶部状态栏已隐藏、本就有
    // 空区，clamp≥0 贴安全区即可；底部手势导航条是半透明浮层会向上盖住一段，
    // clamp≥8 让 HUD 抬高避开手势条。
    final hudInsetTop = (vPad - 20).clamp(0.0, vPad);
    final hudInsetBottom = (vPad - 20).clamp(8.0, vPad);
    final top = MediaQuery.paddingOf(context).top + hudInsetTop;
    final bottom = MediaQuery.paddingOf(context).bottom + hudInsetBottom;
    return IgnorePointer(
      child: Stack(
        fit: StackFit.expand,
        children: [
          Positioned(
            top: top,
            left: hPad,
            child: _ClockText(style: style),
          ),
          Positioned(
            top: top,
            right: hPad,
            child: ValueListenableBuilder<int>(
              valueListenable: _currentPageNotifier,
              builder: (_, p, _) {
                final total = _isImageMode
                    ? _imageBlockIndices.length
                    : _pages.length;
                return Text(total > 0 ? '${p + 1}/$total' : '', style: style);
              },
            ),
          ),
          Positioned(
            bottom: bottom,
            left: hPad,
            right: hPad,
            child: Row(
              children: [
                Expanded(
                  child: ValueListenableBuilder<int>(
                    valueListenable: _currentPageNotifier,
                    builder: (_, _, _) {
                      return Text(
                        _currentChapterTitle(),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: style,
                      );
                    },
                  ),
                ),
                ValueListenableBuilder<int>(
                  valueListenable: _currentPageNotifier,
                  builder: (_, p, _) {
                    final total = _isImageMode
                        ? _imageBlockIndices.length
                        : _pages.length;
                    if (total <= 0) return const SizedBox.shrink();
                    final pct = ((p + 1) / total * 100)
                        .clamp(0, 100)
                        .toStringAsFixed(0);
                    return Text('$pct%', style: style);
                  },
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  // ---------------- 控制层 ----------------

  Widget _buildControls(bool isDark, Color textColor) {
    final barColor = isDark
        ? Colors.black.withValues(alpha: 0.55)
        : Colors.white.withValues(alpha: 0.92);
    final iconColor = isDark ? Colors.white : JellyTheme.textPrimaryLight;
    return AnimatedOpacity(
      opacity: _showControls ? 1.0 : 0.0,
      duration: const Duration(milliseconds: 200),
      child: IgnorePointer(
        ignoring: !_showControls,
        child: Column(
          children: [
            // 顶部栏
            Container(
              color: barColor,
              child: SafeArea(
                bottom: false,
                child: Row(
                  children: [
                    IconButton(
                      icon: Icon(Icons.arrow_back_rounded, color: iconColor),
                      onPressed: () => Navigator.maybePop(context),
                    ),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            widget.task.title,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: 14,
                              fontWeight: FontWeight.w600,
                              color: iconColor,
                            ),
                          ),
                          if (_content != null)
                            Text(
                              _currentChapterTitle(),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(fontSize: 11, color: iconColor),
                            ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
            Expanded(
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: _toggleControls,
                child: const SizedBox.expand(),
              ),
            ),
            // 底部栏
            Container(
              color: barColor,
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
              child: SafeArea(
                top: false,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        TextButton.icon(
                          onPressed: _chapterStarts.isNotEmpty
                              ? () => _goChapter(_currentChapterIndex() - 1)
                              : null,
                          icon: Icon(Icons.chevron_left, color: iconColor),
                          label: Text(
                            '上一章',
                            style: TextStyle(color: iconColor),
                          ),
                        ),
                        Text(
                          _indicatorText(),
                          style: TextStyle(fontSize: 12, color: iconColor),
                        ),
                        TextButton.icon(
                          onPressed: _chapterStarts.isNotEmpty
                              ? () => _goChapter(_currentChapterIndex() + 1)
                              : null,
                          icon: Icon(Icons.chevron_right, color: iconColor),
                          label: Text(
                            '下一章',
                            style: TextStyle(color: iconColor),
                          ),
                        ),
                      ],
                    ),
                    Row(
                      children: [
                        const Expanded(child: SizedBox()),
                        // PDF（懒加载）强制进图片模式，故切换按钮对 PDF 始终可用；
                        // 其余格式沿用 >=10 启发式（仅图片书显示）。
                        if (_imageBlockIndices.length >= 10 ||
                            _content?.imageLoader != null)
                          TextButton.icon(
                            onPressed: _toggleImageMode,
                            icon: Icon(
                              _isImageMode
                                  ? Icons.article_rounded
                                  : Icons.image_rounded,
                              color: iconColor,
                            ),
                            label: Text(
                              _isImageMode ? '文本' : '图片',
                              style: TextStyle(color: iconColor),
                            ),
                          ),
                        if (!_isImageMode)
                          TextButton.icon(
                            onPressed: _showTypoSheet,
                            icon: Icon(
                              Icons.text_fields_rounded,
                              color: iconColor,
                            ),
                            label: Text(
                              '排版',
                              style: TextStyle(color: iconColor),
                            ),
                          ),
                        Expanded(
                          child: Align(
                            alignment: Alignment.centerRight,
                            child: TextButton.icon(
                              onPressed: _showToc,
                              icon: Icon(
                                Icons.menu_book_rounded,
                                color: iconColor,
                              ),
                              label: Text(
                                '目录',
                                style: TextStyle(color: iconColor),
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  int _currentChapterIndex() {
    if (_isImageMode) {
      if (_imageBlockIndices.isEmpty) return 0;
      final idx = _currentImageIndex.clamp(0, _imageBlockIndices.length - 1);
      return _chapterIndexForBlock(_imageBlockIndices[idx]);
    }
    if (_pages.isEmpty) return 0;
    final idx = _currentPage.clamp(0, _pages.length - 1);
    return _chapterIndexForBlock(_pages[idx].firstBlockIndex);
  }

  int _chapterIndexForBlock(int blockIndex) {
    final starts = _chapterStarts;
    if (starts.isEmpty) return 0;
    var ans = 0;
    for (var i = 0; i < starts.length; i++) {
      if (starts[i] <= blockIndex) {
        ans = i;
      } else {
        break;
      }
    }
    return ans;
  }

  String _currentChapterTitle() {
    final ci = _currentChapterIndex();
    final chapters = _content?.chapters ?? const [];
    if (ci < chapters.length) return chapters[ci].title;
    return '';
  }

  String _indicatorText() {
    if (_isImageMode) {
      if (_imageBlockIndices.isEmpty) return '';
      return '${_currentImageIndex + 1}/${_imageBlockIndices.length} 图';
    }
    if (_pages.isEmpty) return '';
    return '${_currentPage + 1}/${_pages.length} 页';
  }

  // ---------------- 目录 ----------------

  void _showToc() {
    final chapters = _content?.chapters ?? const [];
    if (chapters.isEmpty) return;
    final drawerWidth = MediaQuery.sizeOf(context).width * 0.75;
    final currentIndex = _currentChapterIndex();
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
                              '${chapters.length} 章',
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
                                _goChapter(i);
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

  // ---------------- 排版设置 ----------------

  void _showTypoSheet() {
    final s = SettingsService();
    // 草稿：滑块只改草稿，点「确认」才写入 SettingsService 触发重排
    double draftFontSize = s.bookFontSize;
    double draftLineHeight = s.bookLineHeight;
    double draftHPadding = s.bookHorizontalPadding;
    double draftVPadding = s.bookVerticalPadding;
    showModalBottomSheet(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setSheet) {
          final isDark = Theme.of(ctx).brightness == Brightness.dark;
          return SafeArea(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(20, 16, 20, 20),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  _typoSlider(
                    label: '字号',
                    value: draftFontSize,
                    min: SettingsService.minBookFontSize,
                    max: SettingsService.maxBookFontSize,
                    divisions:
                        ((SettingsService.maxBookFontSize -
                                    SettingsService.minBookFontSize) *
                                2)
                            .round(),
                    display: draftFontSize.toStringAsFixed(0),
                    onChanged: (v) {
                      setSheet(() => draftFontSize = v);
                    },
                    isDark: isDark,
                  ),
                  _typoSlider(
                    label: '行距',
                    value: draftLineHeight,
                    min: SettingsService.minBookLineHeight,
                    max: SettingsService.maxBookLineHeight,
                    divisions:
                        ((SettingsService.maxBookLineHeight -
                                    SettingsService.minBookLineHeight) *
                                10)
                            .round(),
                    display: draftLineHeight.toStringAsFixed(1),
                    onChanged: (v) {
                      setSheet(() => draftLineHeight = v);
                    },
                    isDark: isDark,
                  ),
                  _typoSlider(
                    label: '左右边距',
                    value: draftHPadding,
                    min: SettingsService.minBookHorizontalPadding,
                    max: SettingsService.maxBookHorizontalPadding,
                    divisions:
                        (SettingsService.maxBookHorizontalPadding -
                                SettingsService.minBookHorizontalPadding)
                            .round(),
                    display: draftHPadding.toStringAsFixed(0),
                    onChanged: (v) {
                      setSheet(() => draftHPadding = v);
                    },
                    isDark: isDark,
                  ),
                  _typoSlider(
                    label: '上下边距',
                    value: draftVPadding,
                    min: SettingsService.minBookVerticalPadding,
                    max: SettingsService.maxBookVerticalPadding,
                    divisions:
                        (SettingsService.maxBookVerticalPadding -
                                SettingsService.minBookVerticalPadding)
                            .round(),
                    display: draftVPadding.toStringAsFixed(0),
                    onChanged: (v) {
                      setSheet(() => draftVPadding = v);
                    },
                    isDark: isDark,
                  ),
                  const SizedBox(height: 8),
                  Row(
                    children: [
                      TextButton(
                        onPressed: () => Navigator.pop(ctx),
                        child: const Text('取消'),
                      ),
                      const Spacer(),
                      FilledButton(
                        onPressed: () {
                          s.setBookFontSize(draftFontSize);
                          s.setBookLineHeight(draftLineHeight);
                          s.setBookHorizontalPadding(draftHPadding);
                          s.setBookVerticalPadding(draftVPadding);
                          Navigator.pop(ctx);
                        },
                        child: const Text('确认'),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  Widget _typoSlider({
    required String label,
    required double value,
    required double min,
    required double max,
    required int divisions,
    required String display,
    required ValueChanged<double> onChanged,
    required bool isDark,
  }) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          SizedBox(
            width: 40,
            child: Text(
              label,
              style: const TextStyle(fontWeight: FontWeight.w600),
            ),
          ),
          Expanded(
            child: Slider(
              value: value,
              min: min,
              max: max,
              divisions: divisions,
              activeColor: JellyTheme.primary,
              onChanged: onChanged,
            ),
          ),
          SizedBox(
            width: 40,
            child: Text(
              display,
              textAlign: TextAlign.end,
              style: TextStyle(
                color: JellyTheme.primary,
                fontWeight: FontWeight.bold,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// PDF 单页懒加载图：images 未预载时，按需经 [BookContent.imageLoader] 光栅化，
/// 拿到字节后回调父级缓存进 [BookContent.images]，下次构建直接命中缓存分支。
class _PdfPageImage extends StatefulWidget {
  final String imageKey;
  final double contentWidth;
  final Future<Uint8List> Function(String, double) loader;
  final void Function(String imageKey, Uint8List bytes) onLoaded;

  const _PdfPageImage({
    required this.imageKey,
    required this.contentWidth,
    required this.loader,
    required this.onLoaded,
  });

  @override
  State<_PdfPageImage> createState() => _PdfPageImageState();
}

class _PdfPageImageState extends State<_PdfPageImage> {
  Uint8List? _bytes;
  Object? _error;
  bool _loading = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (!_loading && _bytes == null && _error == null) {
      _load();
    }
  }

  Future<void> _load() async {
    if (_loading) return;
    _loading = true;
    // 按设备像素光栅化，保证清晰；contentWidth 为逻辑像素
    final dpr = MediaQuery.devicePixelRatioOf(context);
    try {
      final b = await widget.loader(widget.imageKey, widget.contentWidth * dpr);
      if (!mounted) return;
      setState(() => _bytes = b);
      widget.onLoaded(widget.imageKey, b);
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = e);
    } finally {
      _loading = false;
    }
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    if (_bytes != null) {
      return Image.memory(
        _bytes!,
        width: widget.contentWidth,
        fit: BoxFit.contain,
        gaplessPlayback: true,
        color: isDark ? Colors.white : null,
        colorBlendMode: isDark ? BlendMode.difference : null,
      );
    }
    if (_error != null) {
      return const Padding(
        padding: EdgeInsets.all(24),
        child: Center(child: Icon(Icons.broken_image_outlined, size: 40)),
      );
    }
    return const SizedBox(
      height: 200,
      child: Center(child: CircularProgressIndicator()),
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

/// PDF 懒加载图源：把 [BookContent.imageLoader] 的按需光栅化包装成
/// [ImageProvider]，复用 Flutter 图片缓存（key=imageKey+targetWidth），
/// 使 [precacheImage] 预载与 [Image.gaplessPlayback] 平滑出图成为可能。
/// 用于图片模式（消散 / PhotoView 画廊）渲染 PDF 每页；文本模式仍走 _PdfPageImage。
class _PdfPageImageProvider extends ImageProvider<_PdfPageImageProvider> {
  final String imageKey;
  final double targetWidth; // 物理像素
  final Future<Uint8List> Function(String, double) loader;

  const _PdfPageImageProvider(this.imageKey, this.targetWidth, this.loader);

  @override
  Future<_PdfPageImageProvider> obtainKey(ImageConfiguration _) async => this;

  @override
  ImageStreamCompleter loadImage(
    _PdfPageImageProvider key,
    ImageDecoderCallback decode,
  ) {
    return MultiFrameImageStreamCompleter(
      codec: _loadAsync(key, decode),
      scale: 1.0,
    );
  }

  Future<ui.Codec> _loadAsync(
    _PdfPageImageProvider key,
    ImageDecoderCallback decode,
  ) async {
    final bytes = await loader(key.imageKey, key.targetWidth);
    return decode(await ui.ImmutableBuffer.fromUint8List(bytes));
  }

  @override
  bool operator ==(Object other) =>
      other is _PdfPageImageProvider &&
      other.imageKey == imageKey &&
      other.targetWidth == targetWidth;

  @override
  int get hashCode => Object.hash(imageKey, targetWidth);
}
