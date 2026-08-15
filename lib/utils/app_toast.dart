import 'dart:async';

import 'package:flutter/material.dart';

import '../theme/jelly_theme.dart';

/// 全局轻量气泡服务（全静态）。
///
/// 不依赖 [BuildContext]：持有 [MaterialApp] 的全局 [navigatorKey]，通过其 root
/// [Overlay] 插入顶部气泡，因此浮在所有路由之上（含漫画详情页/阅读器等 push 页面），
/// 下载完成等事件可直接 `AppToast.show(...)`。同时只显示一条，后到的覆盖前一条。
///
/// 内容拆成 [title]（书名，超长时省略号截断）+ [status]（如"下载成功"，始终完整），
/// 保证状态文字在任何标题长度下都可见。
class AppToast {
  AppToast._();

  static GlobalKey<NavigatorState>? _key;
  static OverlayEntry? _current;

  /// 在 `main` 的 initState 调用一次，注入 MaterialApp 的 navigatorKey。
  static void init(GlobalKey<NavigatorState> key) => _key = key;

  /// 显示一条顶部气泡。[title] 超长会被截断，[status] 始终完整显示。新气泡覆盖旧的。
  static void show(String title, String status, {bool isError = false}) {
    final overlay = _key?.currentState?.overlay;
    if (overlay == null) return;
    _current?.remove();
    _current = null;
    late OverlayEntry entry;
    entry = OverlayEntry(
      builder: (_) => _BubbleView(
        title: title,
        status: status,
        isError: isError,
        onDone: () {
          if (identical(_current, entry)) _current = null;
          entry.remove();
        },
      ),
    );
    _current = entry;
    overlay.insert(entry);
  }
}

/// 顶部气泡视图：淡入 + 下滑入场，约 2s 后反向淡出并移除。
class _BubbleView extends StatefulWidget {
  const _BubbleView({
    required this.title,
    required this.status,
    required this.isError,
    required this.onDone,
  });

  final String title;
  final String status;
  final bool isError;
  final VoidCallback onDone;

  @override
  State<_BubbleView> createState() => _BubbleViewState();
}

class _BubbleViewState extends State<_BubbleView>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl;
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 220),
    )..forward();
    _timer = Timer(const Duration(seconds: 2), () {
      if (mounted) _ctrl.reverse().then((_) => widget.onDone());
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final slide = Tween<Offset>(
      begin: const Offset(0, -1),
      end: Offset.zero,
    ).animate(CurvedAnimation(parent: _ctrl, curve: Curves.easeOutCubic));
    final mq = MediaQuery.of(context);
    final style = TextStyle(
      fontSize: 13.5,
      color: widget.isError
          ? const Color(0xFFE57373)
          : (isDark ? Colors.white : Colors.black87),
    );
    return Positioned(
      top: mq.padding.top + 12,
      left: 0,
      right: 0,
      child: IgnorePointer(
        child: FadeTransition(
          opacity: _ctrl,
          child: SlideTransition(
            position: slide,
            child: Center(
              child: ConstrainedBox(
                constraints: BoxConstraints(maxWidth: mq.size.width - 32),
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 16,
                    vertical: 9,
                  ),
                  decoration: BoxDecoration(
                    color: (isDark ? JellyTheme.cardDark : Colors.white)
                        .withValues(alpha: 0.92),
                    borderRadius: BorderRadius.circular(20),
                    border: Border.all(
                      color: widget.isError
                          ? Colors.red.withValues(alpha: 0.4)
                          : (isDark ? Colors.white : Colors.black).withValues(
                              alpha: 0.06,
                            ),
                    ),
                    boxShadow: [
                      BoxShadow(
                        color: Colors.black.withValues(alpha: 0.12),
                        blurRadius: 12,
                        offset: const Offset(0, 4),
                      ),
                    ],
                  ),
                  // 标题可截断，状态固定——保证"下载成功/失败"在长标题下仍可见
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Flexible(
                        child: Text(
                          widget.title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: style,
                        ),
                      ),
                      Text(' ${widget.status}', style: style),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
