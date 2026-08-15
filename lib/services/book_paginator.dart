import 'package:flutter/material.dart';

import '../models/book_content.dart';

/// 图书排版参数：字号 / 行距 / 边距。paginator 与阅读器页共用同一实例，
/// 保证度量高度与实际渲染一致（颜色不影响布局，渲染时 copyWith 颜色）。
class BookTypography {
  final double fontSize;
  final double lineHeight;
  final double padding; // 水平边距
  final double verticalPadding; // 垂直边距（含 HUD 上下留白）
  final String? fontFamily; // 字体；null = 系统默认。度量与渲染共用，确保分页一致

  /// 祖先 DefaultTextStyle.style（取自渲染上下文）。SelectableText/Text 的最终
  /// 样式 = defaultTextStyle.style.merge(widget.style)，defaultTextStyle 的
  /// letterSpacing/fontWeight/fontFamily 等字段会**保留**在渲染端；若度量用裸
  /// paragraphStyle() 则缺这些字段，导致换行/行高不同 -> meas<col（随内容变化、
  /// 逐行累积）。这里把 inheritedStyle merge 进度量样式，使度量 = 渲染 effective
  /// TextStyle（颜色除外，不影响布局）。
  final TextStyle inheritedStyle;

  /// 系统字体缩放器（取自 MediaQuery.textScaler）。渲染由 SelectableText 自动应用，
  /// 度量须在 TextPainter 传入**同一对象**，保证度量与渲染缩放完全一致。系统
  /// TextScaler 可能非线性，不可用 scale(1.0) 重建 TextScaler.linear，否则大字号
  /// 缩放幅度不一致：度量偏小→页底溢出；不传→度量偏大→页底留白。
  final TextScaler textScaler;

  /// 文本高度行为（首行 ascent / 末行 descent / leading 分布）。度量与渲染须用
  /// 同一值：SelectableText 内部 EditableText 取 defaultTextStyle.textHeightBehavior，
  /// 真机该值可能被平台/MediaQuery 注入为非默认；而 TextPainter 默认用引擎默认值。
  /// 两端不一致 -> 行高偏差 -> 页底横切/留白。此处显式固定，两端共用。
  final TextHeightBehavior textHeightBehavior;

  const BookTypography({
    required this.fontSize,
    required this.lineHeight,
    required this.padding,
    required this.verticalPadding,
    this.fontFamily,
    this.inheritedStyle = const TextStyle(),
    this.textScaler = TextScaler.noScaling,
    this.textHeightBehavior = const TextHeightBehavior(),
  });

  /// 段落 / 块之间的纵向间距
  double get blockSpacing => fontSize * 0.55;

  /// 段落度量样式（无颜色）。先 merge inheritedStyle，使度量与渲染 effective
  /// TextStyle 一致（消除 defaultTextStyle 残留字段差异）。
  TextStyle paragraphStyle() => inheritedStyle.merge(
    TextStyle(fontSize: fontSize, height: lineHeight, fontFamily: fontFamily),
  );

  /// 标题字号：level 越小字号越大
  double headingFontSize(int level) {
    final l = level < 1 ? 1 : (level > 6 ? 6 : level);
    return fontSize + (6 - l) * 2.0 + 2;
  }

  /// 标题度量样式：level 越小字号越大
  TextStyle headingStyle(int level) {
    return inheritedStyle.merge(
      TextStyle(
        fontSize: headingFontSize(level),
        height: lineHeight,
        fontWeight: FontWeight.w700,
        fontFamily: fontFamily,
      ),
    );
  }

  /// 强制行高 strut：分页度量与渲染共用同一 strut，消除 TextPainter 与
  /// SelectableText/Text 的行高偏差（不同设备字体度量不同，否则多行累积
  /// 到页底会溢出）。
  StrutStyle strutStyleFor(double size) =>
      StrutStyle(fontSize: size, height: lineHeight, forceStrutHeight: true);

  StrutStyle get paragraphStrut => strutStyleFor(fontSize);

  StrutStyle headingStrut(int level) => strutStyleFor(headingFontSize(level));
}

/// 一页中的一条内容（可能是整块，或段落被切分后的部分文本）
class PageEntry {
  final BookBlock block;

  /// null = 整块原样；非 null = 段落/标题切分后的部分文本
  final String? partialText;
  const PageEntry(this.block, {this.partialText});
}

/// 分页后的一页
class BookPage {
  /// 该页首 block 在 flatBlocks 中的索引（续读 / TOC 映射用）
  final int firstBlockIndex;
  final List<PageEntry> entries;
  const BookPage({required this.firstBlockIndex, required this.entries});
}

/// TextPainter 度量分页器：把 flatBlocks 按 [BookTypography] 与视口尺寸切成页。
/// 段落跨页按行断点切分（getLineBoundary），不切断半行。
///
/// 支持增量分页：[stepInto] 每次只处理若干 block 便返回，已完成的页追加进
/// 调用方传入的列表，未满的当前页状态保留在分页器内部跨调用延续。这样调用方
/// 可在每批之间 `await Future.delayed(Duration.zero)` 让出 UI 线程，避免大书
/// 单章同步度量冻结界面（度量仍用 TextPainter + strut，与渲染一致）。
class BookPaginator {
  /// sub-pixel 安全余量：度量"放得下"判断时留 0.5px，防止 TextPainter 与渲染
  /// 间的浮点误差累积到页底溢出（用户表现为"多一点点"）。
  static const double _kEps = 0.5;

  /// 页底安全余量：度量页高再扣 4px，吸收 TextPainter 度量与真机渲染间的微小
  /// 偏差，配合渲染端 ClipRect 兜底，避免末行被裁。
  static const double _kSafety = 4.0;

  final List<BookBlock> blocks;
  final double viewportWidth;
  final double viewportHeight;
  final BookTypography typo;

  /// imageKey -> 宽/高（阅读器解码图片后回填；未知按 1.5 估算）
  final Map<String, double> imageAspectRatios;

  /// imageKey -> 图片自然像素宽度（与逻辑像素 1:1）。行内小图标（如"注"标记）
  /// 宽度小于内容区时按自然尺寸分页，不被满宽放大；未知按满宽处理。
  final Map<String, int> imageNaturalWidths;

  /// 章节首 block 索引集合：这些 block 强制起新页（复刻按章独立分页行为，
  /// 避免整本增量分页时章标题接在上一章末尾页）
  final Set<int> chapterStarts;

  BookPaginator({
    required this.blocks,
    required this.viewportWidth,
    required this.viewportHeight,
    required this.typo,
    this.imageAspectRatios = const {},
    this.imageNaturalWidths = const {},
    this.chapterStarts = const {},
  });

  /// 断点续分页：从持久化的 partial 状态恢复，继续 stepInto。
  /// [cur] 为退出时半满页 entries，[remaining] 该页剩余高度，
  /// [resumeBlockIndex] 下一个待处理 block 索引。[blocks] 须与原次同源
  /// （即 content.flatBlocks），保证续出的 block identity 与主线程一致。
  BookPaginator.resume({
    required this.blocks,
    required this.viewportWidth,
    required this.viewportHeight,
    required this.typo,
    this.imageAspectRatios = const {},
    this.imageNaturalWidths = const {},
    this.chapterStarts = const {},
    required int resumeBlockIndex,
    required List<PageEntry> cur,
    required int curFirst,
    required double remaining,
  }) {
    _i = resumeBlockIndex;
    _curFirst = curFirst;
    _remaining = remaining;
    _cur.addAll(cur);
    _inited = true; // 跳过 _initOnce，直接用传入的 _remaining/_cur 续
  }

  // ---- 增量状态 ----
  late final double _contentWidth = viewportWidth - typo.padding * 2;
  late final double _pageHeight =
      viewportHeight - typo.verticalPadding * 2 - _kSafety;
  final List<PageEntry> _cur = []; // 当前未满页
  final List<BookPage> _donePages = []; // 已 commit 的完整页（待调用方取走）
  int _curFirst = 0;
  double _remaining = 0;
  int _i = 0; // 下一个待处理 block 索引
  bool _inited = false;
  bool _finished = false;

  /// 已处理到的 block 索引（供调用方显示进度 / 反推章节数）
  int get currentBlockIndex => _i;
  bool get finished => _finished;
  int get blockCount => blocks.length;

  /// 当前增量状态快照（partial 缓存续分页用）：半满页 entries / 首块 /
  /// 剩余高度 / 下一个待处理 block 索引。dispose 写 partial 时捕获此快照。
  ({List<PageEntry> cur, int curFirst, double remaining, int blockIndex})
  get snapshot => (
    cur: List.of(_cur),
    curFirst: _curFirst,
    remaining: _remaining,
    blockIndex: _i,
  );

  void _initOnce() {
    if (_inited) return;
    _inited = true;
    _remaining = _pageHeight;
    // 视口非法直接结束，避免无效度量
    if (_pageHeight <= 0 || _contentWidth <= 0 || blocks.isEmpty) {
      _finished = true;
    }
  }

  void _commitPage() {
    if (_cur.isNotEmpty) {
      // 复制一份：_cur 复用清空，已提交页不能受影响
      _donePages.add(
        BookPage(firstBlockIndex: _curFirst, entries: List.of(_cur)),
      );
    }
    _cur.clear();
    _remaining = _pageHeight;
  }

  /// 处理单个 block（原 paginate 循环体）
  void _processBlock(int i) {
    // 章节首 block 强制起新页（与原按章独立分页行为一致）
    if (_cur.isNotEmpty && chapterStarts.contains(i)) {
      _commitPage();
    }
    final block = blocks[i];
    if (_cur.isEmpty) _curFirst = i;

    // 分隔线
    if (block is DividerBlock) {
      const h = 16.0;
      if (_remaining < h + typo.blockSpacing) _commitPage();
      _cur.add(const PageEntry(DividerBlock()));
      _remaining -= h + typo.blockSpacing;
      return;
    }

    // 图片
    if (block is ImageBlock) {
      final ar = imageAspectRatios[block.imageKey] ?? block.aspectRatio ?? 1.5;
      final naturalW = imageNaturalWidths[block.imageKey];
      // 行内标注图标（小且接近正方形）：按字号高度分页，不占满宽（与渲染一致）
      final isInlineIcon =
          naturalW != null && naturalW <= 256 && ar >= 0.7 && ar <= 1.4;
      final imgW = isInlineIcon ? typo.fontSize * 0.8 : _contentWidth;
      var imgH = isInlineIcon ? imgW : imgW / ar;
      if (imgH > _pageHeight) imgH = _pageHeight; // 超高图限制为一页高
      if (imgH > _remaining && _cur.isNotEmpty) {
        _commitPage();
        _curFirst = i;
      }
      _cur.add(PageEntry(block));
      _remaining -= imgH + typo.blockSpacing;
      return;
    }

    // 段落 / 标题：文本度量（strut 强制行高，与渲染一致）
    final isHeading = block is HeadingBlock;
    final text = isHeading ? block.text : (block as ParagraphBlock).text;
    final style = isHeading
        ? typo.headingStyle(block.level)
        : typo.paragraphStyle();
    final strut = isHeading
        ? typo.headingStrut(block.level)
        : typo.paragraphStrut;

    final tp = TextPainter(
      text: TextSpan(text: text, style: style),
      strutStyle: strut,
      textScaler: typo.textScaler,
      textHeightBehavior: typo.textHeightBehavior,
      textDirection: TextDirection.ltr,
    )..layout(maxWidth: _contentWidth);
    // 标题渲染带 Padding(top:4)（见 _buildEntry），度量须计入，否则标题页累积溢出。
    final totalH = tp.height + (isHeading ? 4.0 : 0.0);

    if (totalH + _kEps <= _remaining) {
      // 整块放得下
      _cur.add(PageEntry(block));
      _remaining -= totalH + typo.blockSpacing;
      return;
    }

    // 放不下当前页剩余：按行切分，先填满当前页剩余（短段落也跨页，消除页底
    // 留白），再逐页填满。仅当当前页剩余不足一行时才整段移新页（留白 < 一行高）。
    var rest = text;
    var firstChunk = true; // rest 是否为该块起始（整段放时 partialText 判空）
    while (rest.isNotEmpty) {
      final tp2 = TextPainter(
        text: TextSpan(text: rest, style: style),
        strutStyle: strut,
        textScaler: typo.textScaler,
        textHeightBehavior: typo.textHeightBehavior,
        textDirection: TextDirection.ltr,
      )..layout(maxWidth: _contentWidth);
      // 当前页可用高度：当前页已有内容用 _remaining，空页用 _pageHeight
      final avail = _cur.isNotEmpty ? _remaining : _pageHeight;
      if (tp2.height + _kEps <= avail) {
        // 剩余全部放得下当前页
        _cur.add(PageEntry(block, partialText: firstChunk ? null : rest));
        _remaining = avail - tp2.height - typo.blockSpacing;
        rest = '';
      } else {
        // 按行切分填满 avail
        var fitEnd = _fitOffset(tp2, avail);
        if (fitEnd <= 0) {
          if (_cur.isNotEmpty) {
            // 当前页剩余放不下一行：提交当前页（留白 < 一行高），新页继续
            _commitPage();
            _curFirst = i;
            continue;
          }
          // 新页也放不下一行（视口过小），强制取一行避免死循环
          final range = tp2.getLineBoundary(const TextPosition(offset: 0));
          fitEnd = range.end > range.start ? range.end : 1;
        }
        _cur.add(PageEntry(block, partialText: rest.substring(0, fitEnd)));
        _remaining = 0;
        rest = rest.substring(fitEnd).trimLeft();
        _commitPage();
        _curFirst = i;
      }
      firstChunk = false;
    }
  }

  /// 增量分页：处理最多 [chunk] 个 block，已 commit 的完整页追加进 [out]。
  /// 未满的当前页保留在内部跨调用延续；返回是否已处理完全部 block。
  bool stepInto(List<BookPage> out, {int chunk = 12}) {
    _initOnce();
    if (_finished) return true;
    final end = (_i + chunk).clamp(0, blocks.length);
    while (_i < end) {
      _processBlock(_i);
      _i++;
    }
    out.addAll(_donePages);
    _donePages.clear();
    if (_i >= blocks.length && !_finished) {
      _commitPage(); // 提交最后一页
      out.addAll(_donePages);
      _donePages.clear();
      _finished = true;
    }
    return _finished;
  }

  /// 一次性全量分页（等价于循环 stepInto 到完成）。供同步场景。
  List<BookPage> paginate() {
    final out = <BookPage>[];
    while (!stepInto(out, chunk: blocks.length)) {}
    return out;
  }

  /// 返回在 [maxHeight] 内能放下的文本字符偏移（行末对齐）。
  ///
  /// 用实测 partialText 高度判准（与渲染同源 TextPainter），避免 computeLineMetrics
  /// 的行高与 forceStrutHeight 实际渲染行高有 sub-pixel 偏差导致多放一行/半行而溢出。
  /// 二分定位最多可放行数，O(log 行数) 次度量。
  int _fitOffset(TextPainter tp, double maxHeight) {
    final metrics = tp.computeLineMetrics();
    if (metrics.isEmpty) return 0;
    // 收集各行末偏移
    final lineEnds = <int>[];
    var cursor = 0;
    for (var i = 0; i < metrics.length; i++) {
      final range = tp.getLineBoundary(TextPosition(offset: cursor));
      if (range.end <= range.start) break;
      lineEnds.add(range.end);
      cursor = range.end;
    }
    if (lineEnds.isEmpty) return 0;
    final full = tp.text!.toPlainText();
    final spanStyle = (tp.text! as TextSpan).style;
    final strut = tp.strutStyle;
    final scaler = tp.textScaler;
    double heightOf(int end) {
      final p = TextPainter(
        text: TextSpan(text: full.substring(0, end), style: spanStyle),
        strutStyle: strut,
        textScaler: scaler,
        textHeightBehavior: typo.textHeightBehavior,
        textDirection: TextDirection.ltr,
      )..layout(maxWidth: _contentWidth);
      final h = p.height;
      p.dispose();
      return h;
    }

    // 二分找最多能完整放下的行数
    var lo = 1, hi = lineEnds.length, ans = 0;
    while (lo <= hi) {
      final mid = (lo + hi) ~/ 2;
      if (heightOf(lineEnds[mid - 1]) + _kEps <= maxHeight) {
        ans = mid;
        lo = mid + 1;
      } else {
        hi = mid - 1;
      }
    }
    return ans == 0 ? 0 : lineEnds[ans - 1];
  }

  /// 找包含给定 blockIndex 的页索引（续读恢复用）
  static int pageIndexOf(List<BookPage> pages, int blockIndex) {
    if (pages.isEmpty) return 0;
    var lo = 0, hi = pages.length - 1, ans = 0;
    while (lo <= hi) {
      final mid = (lo + hi) ~/ 2;
      if (pages[mid].firstBlockIndex <= blockIndex) {
        ans = mid;
        lo = mid + 1;
      } else {
        hi = mid - 1;
      }
    }
    return ans;
  }
}
