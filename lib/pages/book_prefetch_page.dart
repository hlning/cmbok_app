import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

import '../models/book_content.dart';
import '../services/book_content_cache_service.dart';
import '../services/book_download_service.dart';
import '../services/book_page_cache_service.dart';
import '../services/book_parser.dart';
import '../services/book_paginator.dart';
import '../services/book_reading_progress_service.dart';
import '../services/reader_override_service.dart';
import '../theme/jelly_theme.dart';
import 'book_reader_page.dart';

/// 阅读器前置页：解析 + 分页 + 缓存就绪后再进入阅读器。
/// 命中缓存时仅解析文件（"加载中"）；首次 / 参数变更时完整分页（"排版中 X/Y 章"），
/// 排完写入缓存，再 [pushReplacement] 到 [BookReaderPage]（带预计算结果，跳过 _load/_paginate）。
class BookPrefetchPage extends StatefulWidget {
  final BookDownloadTask task;
  const BookPrefetchPage({super.key, required this.task});

  @override
  State<BookPrefetchPage> createState() => _BookPrefetchPageState();
}

class _BookPrefetchPageState extends State<BookPrefetchPage> {
  BookContent? _content;
  // 解析时同 isolate 解出的图片宽高比，供 _paginate 复用，
  // 省一次跨 isolate 传 images（解析缓存命中时为空，仍走 _decodeImageInfo）
  Map<String, double>? _ratios;
  // 同上，图片自然像素宽度（行内小图标判定用）
  Map<String, int>? _naturalWidths;
  bool _started = false;
  bool _disposed = false;
  String _phase = '加载中...';

  @override
  void initState() {
    super.initState();
    _parse();
  }

  @override
  void dispose() {
    _disposed = true; // 取消异步解析/分页，防离开后仍 pushReplacement 进阅读器
    super.dispose();
  }

  void _log(String msg) {
    if (kDebugMode) print('[BookPrefetch] $msg');
  }

  Future<void> _parse() async {
    final task = widget.task;
    final path = task.localPath;
    if (path == null || !await File(path).exists()) {
      _enterReader(null); // 交阅读器显示"文件不存在"
      return;
    }
    // 让"加载中"首帧先渲染再启动解析，避免点击瞬间空白
    await Future.delayed(Duration.zero);
    final file = File(path);
    final ext = (task.extension ?? 'epub').toLowerCase();
    // PDF 不走解析缓存：imageLoader 不可序列化，images 懒加载为空，缓存无意义
    final fp = ext == 'pdf'
        ? null
        : await BookContentCacheService.instance.fingerprintOf(file);
    // 解析缓存命中：跳过 compute 解析（EPUB 解压+XML 约 1s），直接进分页流程
    final cached = fp == null
        ? null
        : await BookContentCacheService.instance.read(
            bookId: task.bookId,
            fingerprint: fp,
          );
    if (cached != null) {
      _log('解析缓存命中，跳过解析');
      if (!mounted) return;
      setState(() => _content = cached);
      return;
    }
    try {
      final sw = Stopwatch()..start();
      // 解析 + 图片宽高比合并到同一 isolate，省 images 一次跨 isolate
      // 深拷贝（图片多的大书进入卡顿主因）
      BookContent content;
      Map<String, double>? ratios;
      Map<String, int>? naturalWidths;
      if (ext == 'pdf') {
        // PDF 走主线程解析（PdfRenderer channel 不可在 isolate）；
        // 比例已在 ImageBlock.aspectRatio，无需解码图片
        content = await BookParser.parsePdf(file);
        ratios = const {};
        naturalWidths = const {};
      } else if (ext == 'txt') {
        content = await compute(BookParser.parseTxt, file);
      } else if (ext == 'mobi' || ext == 'azw' || ext == 'azw3') {
        final r = await compute(BookParser.parseMobiWithRatios, file);
        content = r.content;
        ratios = r.ratios;
        naturalWidths = r.naturalWidths;
      } else {
        final r = await compute(BookParser.parseEpubWithRatios, file);
        content = r.content;
        ratios = r.ratios;
        naturalWidths = r.naturalWidths;
      }
      _log(
        '解析 $ext ${content.flatBlocks.length} 块 ${sw.elapsedMilliseconds}ms',
      );
      if (!mounted) return;
      setState(() {
        _content = content;
        _ratios = ratios;
        _naturalWidths = naturalWidths;
      });
      // 后台写解析缓存，不阻塞分页；失败忽略。PDF 不写（imageLoader 不可序列化）
      if (ext != 'pdf') {
        unawaited(
          BookContentCacheService.instance.write(
            bookId: task.bookId,
            fingerprint: fp!,
            content: content,
          ),
        );
      }
    } catch (_) {
      if (mounted) _enterReader(null); // 交阅读器显示解析错误
    }
  }

  BookTypography _typoFromSettings() {
    // 与阅读器 _typoFromSettings 完全一致：独立设置开启时取 per-item 覆盖，
    // 否则回退全局。确保 prefetch 与 reader 生成的分页缓存 key 一致，
    // 否则独立设置开启时 prefetch 写入的缓存 key 与 reader 计算的永远不同，
    // reader 进入后判 miss 触发前台重排且写出的缓存也命不中（等于废缓存）。
    final o = ReaderOverrideService();
    final bookId = widget.task.bookId;
    final mode = o.effectiveBookMode(bookId);
    return BookTypography(
      fontSize: o.effectiveBookFontSize(bookId),
      lineHeight: o.effectiveBookLineHeight(bookId),
      padding: o.effectiveBookHorizontalPadding(bookId),
      verticalPadding: o.effectiveBookVerticalPadding(bookId),
      // 字体族：用户字体偏好优先（含 'system' 哨兵），其次由模式派生。
      // 仿真 → inkReadingKai，普通翻页 → null（系统默认），与阅读器一致。
      fontFamily: ReaderOverrideService.resolveFontFamily(
        o.effectiveBookFontFamily(bookId),
        mode,
      ),
      // 与阅读器一致：inheritedStyle 取渲染端 defaultTextStyle（Scaffold 内 Material
      // 注入的 theme.textTheme.bodyMedium），度量 merge 它以消除 letterSpacing 等
      // 残留字段差异（meas<col）。
      inheritedStyle:
          Theme.of(context).textTheme.bodyMedium ?? const TextStyle(),
      // 与阅读器一致：度量须传入系统 TextScaler 原对象，保证与渲染缩放一致。
      textScaler: MediaQuery.textScalerOf(context),
    );
  }

  Future<void> _paginate(
    BoxConstraints c,
    BuildContext ctx,
    BookContent content,
  ) async {
    final task = widget.task;
    // 视口算法与阅读器 _buildPaged 完全一致，确保 key 判等
    final vpW = c.maxWidth;
    final vpH = c.maxHeight;
    final safeTop = MediaQuery.paddingOf(ctx).top;
    final safeBottom = MediaQuery.paddingOf(ctx).bottom;
    final textVpH = vpH - safeTop - safeBottom;
    if (textVpH <= 0) {
      _enterReader(null);
      return;
    }
    final typo = _typoFromSettings();
    final fp = BookPageCacheService.contentFingerprint(content);
    final key = BookPageCacheService.keyOf(
      vpW: vpW,
      vpH: textVpH,
      typo: typo,
      bookId: task.bookId,
      fingerprint: fp,
    );
    _log('分页视口 vpW=$vpW textVpH=$textVpH key=$key');

    // 命中缓存：跳过图片解码与分页
    final cached = await BookPageCacheService.instance.read(
      bookId: task.bookId,
      key: key,
      content: content,
    );
    if (cached != null) {
      if (cached.partial && cached.resumeBlockIndex != null) {
        // 命中 partial：用 BookPaginator.resume 从断点续，交阅读器后台分完。
        // blocks 须与缓存写入时同源（content.flatBlocks），续出的 block identity
        // 与主线程一致，后续 write idx 才命中。
        final flat = content.flatBlocks;
        final starts = content.chapterStarts;
        final paginator = BookPaginator.resume(
          blocks: flat,
          viewportWidth: vpW,
          viewportHeight: textVpH,
          typo: typo,
          imageAspectRatios: cached.ratios,
          imageNaturalWidths: cached.naturalWidths,
          chapterStarts: starts.toSet(),
          resumeBlockIndex: cached.resumeBlockIndex!,
          cur: cached.cur ?? const [],
          curFirst: cached.curFirst ?? 0,
          remaining: cached.remaining ?? 0.0,
        );
        _log(
          '分页缓存命中(partial) key=$key pages=${cached.pages.length} resume=${cached.resumeBlockIndex}',
        );
        _enterReader(
          BookPrefetchedData(
            content: content,
            pages: cached.pages,
            ratios: cached.ratios,
            naturalWidths: cached.naturalWidths,
            key: key,
            fingerprint: fp,
            paginator: paginator,
          ),
        );
        return;
      }
      _log('分页缓存命中 key=$key pages=${cached.pages.length}');
      _enterReader(
        BookPrefetchedData(
          content: content,
          pages: cached.pages,
          ratios: cached.ratios,
          naturalWidths: cached.naturalWidths,
          key: key,
          fingerprint: fp,
        ),
      );
      return;
    }

    // miss：解码图片宽高比 -> 增量分页（每批让出 UI）-> 写缓存
    // 复用解析时同 isolate 解出的 _ratios（若有），省一次跨 isolate 传 images；
    // 解析缓存命中时 _ratios 为空，仍单独解码
    Map<String, double> ratios;
    Map<String, int> naturalWidths;
    if (_ratios != null) {
      ratios = _ratios!;
      naturalWidths = _naturalWidths ?? const {};
      _log('图片宽高比复用解析结果 ${ratios.length} 张');
    } else {
      if (mounted) setState(() => _phase = '解码图片...');
      final swDecode = Stopwatch()..start();
      final info = await _decodeImageInfo(content);
      ratios = info.ratios;
      naturalWidths = info.naturalWidths;
      _log('图片解码 ${ratios.length} 张 ${swDecode.elapsedMilliseconds}ms');
    }

    final flat = content.flatBlocks;
    final starts = content.chapterStarts;
    final totalChapters = starts.length;
    final paginator = BookPaginator(
      blocks: flat,
      viewportWidth: vpW,
      viewportHeight: textVpH,
      typo: typo,
      imageAspectRatios: ratios,
      imageNaturalWidths: naturalWidths,
      chapterStarts: starts.toSet(),
    );
    final pages = <BookPage>[];
    var chapterDone = 0;
    // 先渲染一帧"排版中"再启动，避免从"加载中"硬切时首批度量冻结界面
    if (mounted) {
      setState(
        () => _phase = totalChapters > 0 ? '排版中 0/$totalChapters 章' : '排版中...',
      );
      SchedulerBinding.instance.scheduleFrame();
      await SchedulerBinding.instance.endOfFrame;
    }
    // 流式阈值：续读位置已覆盖 + 至少 8 页，就先进阅读器，剩余后台补
    final startBlockIndex =
        BookReadingProgressService().getProgress(task.bookId)?.blockIndex ?? 0;
    final swPage = Stopwatch()..start();
    while (!paginator.finished && !_disposed) {
      paginator.stepInto(pages, chunk: 12);
      // 按 block 进度反推已跨过的章节数
      final bi = paginator.currentBlockIndex;
      while (chapterDone < totalChapters && starts[chapterDone] < bi) {
        chapterDone++;
      }
      if (mounted) {
        setState(() => _phase = '排版中 $chapterDone/$totalChapters 章');
      }
      // 够开始读就先进阅读器，剩余交给后台流式分页。
      // 大书续读靠后时：分够 30 页即进，不等分到续读位置（由阅读器后台定位）。
      if (!paginator.finished &&
          pages.length >= 8 &&
          (bi > startBlockIndex || pages.length >= 30)) {
        break;
      }
      SchedulerBinding.instance.scheduleFrame();
      await SchedulerBinding.instance.endOfFrame;
    }
    final partial = !paginator.finished;
    _log(
      '分页 ${flat.length} 块 -> ${pages.length} 页 ${swPage.elapsedMilliseconds}ms'
      '${partial ? '（部分，剩余后台）' : ''}',
    );
    // 整本完成才写缓存；partial 时：未退出则交阅读器后台续（完成回写整本 / 退出写 partial），
    // 已退出（_disposed，未进阅读器）则写 partial，下次断点续分页，不再从头重排。
    if (!partial) {
      await BookPageCacheService.instance.write(
        bookId: task.bookId,
        key: key,
        pages: pages,
        ratios: ratios,
        naturalWidths: naturalWidths,
        flatBlocks: flat,
      );
      _log('写分页缓存(整本) key=$key pages=${pages.length}');
    } else if (_disposed) {
      final snap = paginator.snapshot;
      await BookPageCacheService.instance.write(
        bookId: task.bookId,
        key: key,
        pages: pages,
        ratios: ratios,
        naturalWidths: naturalWidths,
        flatBlocks: flat,
        partial: true,
        resumeBlockIndex: snap.blockIndex,
        cur: snap.cur,
        curFirst: snap.curFirst,
        remaining: snap.remaining,
      );
      _log(
        '写分页缓存(partial,已退出) key=$key pages=${pages.length} resume=${snap.blockIndex}',
      );
    }
    _enterReader(
      BookPrefetchedData(
        content: content,
        pages: pages,
        ratios: ratios,
        naturalWidths: naturalWidths,
        key: key,
        fingerprint: fp,
        paginator: partial ? paginator : null,
      ),
    );
  }

  Future<({Map<String, double> ratios, Map<String, int> naturalWidths})>
  _decodeImageInfo(BookContent content) async {
    if (content.images.isEmpty) {
      return (
        ratios: const <String, double>{},
        naturalWidths: const <String, int>{},
      );
    }
    // 纯 Dart 读图片头部（不依赖 dart:ui，可在 isolate 安全执行），
    // 避免主线程逐张解码卡 UI；record 含 Map 时 compute 的 R 推断退化为
    // Map<dynamic,dynamic>，这里重建为具体类型。
    final r = await compute(BookParser.decodeImageInfo, content.images);
    return (
      ratios: Map<String, double>.from(r.ratios),
      naturalWidths: Map<String, int>.from(r.naturalWidths),
    );
  }

  void _enterReader(BookPrefetchedData? data) {
    if (_disposed || !mounted) return;
    // 防导航竞态：用户在加载中按返回后本路由已非栈顶（pop 同步改变 isCurrent，早于
    // mounted 变 false），此时不得再 pushReplacement，否则会把栈顶入口页替换成阅读器，
    // 导致再次返回直接退出 App。mounted 要等离场动画那帧才 false，拦不住此窗口。
    final route = ModalRoute.of(context);
    if (route == null || !route.isCurrent) return;
    Navigator.pushReplacement(
      context,
      MaterialPageRoute(
        builder: (_) => BookReaderPage(task: widget.task, prefetched: data),
      ),
    );
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
      // SafeArea(top:false,bottom:false) 与阅读器 _buildPaged 完全一致：
      // 上下不裁（正文手动按安全区留白），左右扣安全区。保证 prefetch 的视口
      // 度量与阅读器渲染区域一致，分页缓存 key 才匹配，reader 进入不重排、
      // 二次打开可命中缓存（否则左右安全区非零的设备每次都 miss 重排）。
      body: SafeArea(
        top: false,
        bottom: false,
        child: LayoutBuilder(
          builder: (ctx, c) {
            final content = _content;
            if (content != null && !_started) {
              _started = true;
              // 延后到帧末再启动分页，避免在 build 期间 setState
              WidgetsBinding.instance.addPostFrameCallback((_) {
                if (mounted) _paginate(c, ctx, content);
              });
            }
            return Center(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  const CircularProgressIndicator(),
                  const SizedBox(height: 16),
                  Text(_phase, style: TextStyle(color: textColor)),
                ],
              ),
            );
          },
        ),
      ),
    );
  }
}
