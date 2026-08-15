import 'dart:async';
import 'dart:math' show pi, cos, sin;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import '../services/settings_service.dart';
import '../theme/jelly_theme.dart';

void _log(String message) {
  if (kDebugMode) {
    print('[PomodoroButton] $message');
  }
}

/// 番茄钟阶段
enum _PomodoroPhase { idle, working, resting, paused }

/// 阅读器底栏番茄钟按钮：点击开始 25 分钟工作计时，到时全屏弹出番茄炸开动画；
/// 长按打开配置弹层（循环次数 1~5、每轮休息 1~15 分钟）。休息只在两轮工作之间
/// 发生，最后一轮工作结束后直接结束。计时用墙钟法，App 后台/息屏恢复后自动补齐。
class PomodoroButton extends StatefulWidget {
  const PomodoroButton({super.key});

  @override
  State<PomodoroButton> createState() => _PomodoroButtonState();
}

class _PomodoroButtonState extends State<PomodoroButton>
    with WidgetsBindingObserver {
  _PomodoroPhase _phase = _PomodoroPhase.idle;
  Timer? _timer;
  DateTime? _phaseEndAt;
  int _remainingSec = 0;
  int _round = 0;
  // 暂停时保存的剩余秒数，恢复时据此重算 phaseEndAt
  int _pausedRemaining = 0;
  // 暂停前所在阶段（working/resting）
  _PomodoroPhase _pausedFrom = _PomodoroPhase.idle;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    _timer?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // 后台/息屏期间 Timer 可能不触发，回到前台时立即重算并补触发到时
    if (state == AppLifecycleState.resumed && _phase != _PomodoroPhase.idle) {
      _tick();
    }
  }

  void _onTap() {
    switch (_phase) {
      case _PomodoroPhase.idle:
        _startWork(round: 1);
        break;
      case _PomodoroPhase.working:
      case _PomodoroPhase.resting:
        _pause();
        break;
      case _PomodoroPhase.paused:
        _resume();
        break;
    }
  }

  void _startWork({required int round}) {
    _round = round;
    _phase = _PomodoroPhase.working;
    final workSec = SettingsService.pomodoroWorkMinutes * 60;
    _remainingSec = workSec;
    _phaseEndAt = DateTime.now().add(Duration(seconds: workSec));
    _startTimer();
    _log('开始第$round轮工作（${SettingsService.pomodoroWorkMinutes}分钟）');
  }

  void _startRest() {
    _phase = _PomodoroPhase.resting;
    final restSec = SettingsService().pomodoroRestMinutes * 60;
    _remainingSec = restSec;
    _phaseEndAt = DateTime.now().add(Duration(seconds: restSec));
    _startTimer();
    _log('开始休息（${SettingsService().pomodoroRestMinutes}分钟）');
  }

  void _startTimer() {
    _timer?.cancel();
    _timer = Timer.periodic(const Duration(seconds: 1), (_) => _tick());
  }

  void _pause() {
    _timer?.cancel();
    _timer = null;
    _pausedRemaining = _remainingSec;
    _pausedFrom = _phase;
    setState(() => _phase = _PomodoroPhase.paused);
  }

  void _resume() {
    _phase = _pausedFrom;
    _phaseEndAt = DateTime.now().add(Duration(seconds: _pausedRemaining));
    _startTimer();
    setState(() {});
  }

  void _stop() {
    _timer?.cancel();
    _timer = null;
    setState(() {
      _phase = _PomodoroPhase.idle;
      _round = 0;
      _remainingSec = 0;
      _phaseEndAt = null;
    });
  }

  void _tick() {
    if (!mounted || _phase == _PomodoroPhase.idle || _phaseEndAt == null) {
      return;
    }
    final remaining = _phaseEndAt!.difference(DateTime.now());
    if (remaining <= Duration.zero) {
      _onPhaseEnd();
      return;
    }
    setState(() => _remainingSec = remaining.inSeconds);
  }

  void _onPhaseEnd() {
    if (_phase == _PomodoroPhase.working) {
      // 每轮工作结束都弹番茄炸开
      _showTomatoBurst();
      final loopCount = SettingsService().pomodoroLoopCount;
      if (_round < loopCount) {
        _startRest();
      } else {
        _stop();
      }
    } else if (_phase == _PomodoroPhase.resting) {
      final loopCount = SettingsService().pomodoroLoopCount;
      _round += 1;
      if (_round <= loopCount) {
        _startWork(round: _round);
      } else {
        _stop();
      }
    }
  }

  String get _countdownText {
    final m = (_remainingSec ~/ 60).toString().padLeft(2, '0');
    final s = (_remainingSec % 60).toString().padLeft(2, '0');
    return '$m:$s';
  }

  void _showConfigSheet() {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (ctx) {
        final isDark = Theme.of(ctx).brightness == Brightness.dark;
        return StatefulBuilder(
          builder: (ctx, setSheet) {
            final s = SettingsService();
            final running = _phase != _PomodoroPhase.idle;
            return SafeArea(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(20, 16, 20, 20),
                child: Container(
                  decoration: JellyTheme.glassDecoration(
                    isDark: isDark,
                  ).copyWith(borderRadius: BorderRadius.circular(20)),
                  padding: const EdgeInsets.fromLTRB(16, 20, 16, 16),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Text(
                        '番茄钟',
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.bold,
                          color: isDark
                              ? Colors.white
                              : JellyTheme.textPrimaryLight,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        '每轮工作 ${SettingsService.pomodoroWorkMinutes} 分钟，轮间休息',
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          fontSize: 12,
                          color: isDark
                              ? Colors.white.withValues(alpha: 0.6)
                              : JellyTheme.textSecondary,
                        ),
                      ),
                      const SizedBox(height: 12),
                      _settingSlider(
                        label: '循环',
                        value: s.pomodoroLoopCount.toDouble(),
                        min: SettingsService.minPomodoroLoopCount,
                        max: SettingsService.maxPomodoroLoopCount,
                        divisions:
                            SettingsService.maxPomodoroLoopCount -
                            SettingsService.minPomodoroLoopCount,
                        suffix: '次',
                        isDark: isDark,
                        onChanged: (v) {
                          s.setPomodoroLoopCount(v.round());
                          setSheet(() {});
                        },
                      ),
                      _settingSlider(
                        label: '休息',
                        value: s.pomodoroRestMinutes.toDouble(),
                        min: SettingsService.minPomodoroRestMinutes,
                        max: SettingsService.maxPomodoroRestMinutes,
                        divisions:
                            SettingsService.maxPomodoroRestMinutes -
                            SettingsService.minPomodoroRestMinutes,
                        suffix: '分',
                        isDark: isDark,
                        onChanged: (v) {
                          s.setPomodoroRestMinutes(v.round());
                          setSheet(() {});
                        },
                      ),
                      if (running) ...[
                        const SizedBox(height: 8),
                        TextButton(
                          onPressed: () {
                            _stop();
                            Navigator.of(ctx).pop();
                          },
                          child: Text(
                            '停止计时',
                            style: TextStyle(color: JellyTheme.error),
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
              ),
            );
          },
        );
      },
    );
  }

  Widget _settingSlider({
    required String label,
    required double value,
    required int min,
    required int max,
    required int divisions,
    required String suffix,
    required bool isDark,
    required ValueChanged<double> onChanged,
  }) {
    final labelColor = isDark ? Colors.white : JellyTheme.textPrimaryLight;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          SizedBox(
            width: 40,
            child: Text(
              label,
              style: TextStyle(fontWeight: FontWeight.w600, color: labelColor),
            ),
          ),
          Expanded(
            child: Slider(
              value: value,
              min: min.toDouble(),
              max: max.toDouble(),
              divisions: divisions,
              activeColor: JellyTheme.primary,
              onChanged: onChanged,
            ),
          ),
          SizedBox(
            width: 44,
            child: Text(
              '${value.round()}$suffix',
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

  void _showTomatoBurst() {
    if (!mounted) return;
    showGeneralDialog(
      context: context,
      barrierDismissible: true,
      barrierLabel: '番茄完成',
      barrierColor: Colors.black54,
      transitionDuration: Duration.zero,
      pageBuilder: (ctx, anim, secondaryAnim) {
        return const Material(
          color: Colors.transparent,
          child: Center(child: _TomatoBurst()),
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final running = _phase != _PomodoroPhase.idle;
    final isRest =
        _phase == _PomodoroPhase.resting ||
        (_phase == _PomodoroPhase.paused &&
            _pausedFrom == _PomodoroPhase.resting);
    final isPaused = _phase == _PomodoroPhase.paused;

    final emoji = isRest ? '☕' : '🍅';
    final countdownColor = isRest
        ? const Color(0xFF4CAF50)
        : const Color(0xFFE53935);

    return TextButton(
      onPressed: _onTap,
      onLongPress: _showConfigSheet,
      style: TextButton.styleFrom(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        minimumSize: const Size(48, 44),
      ),
      child: Opacity(
        opacity: isPaused ? 0.5 : 1,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              emoji,
              style: TextStyle(fontSize: running ? 16 : 20, height: 1),
            ),
            if (running) ...[
              const SizedBox(height: 1),
              Text(
                _countdownText,
                style: TextStyle(
                  fontSize: 9,
                  fontWeight: FontWeight.bold,
                  color: countdownColor,
                  height: 1,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// 番茄炸开动画：红色番茄微胀后炸裂为若干碎片径向飞散 + 重力下落 + 淡出。
class _TomatoBurst extends StatefulWidget {
  const _TomatoBurst();

  @override
  State<_TomatoBurst> createState() => _TomatoBurstState();
}

class _TomatoBurstState extends State<_TomatoBurst>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1200),
    );
    _controller.addStatusListener((status) {
      if (status == AnimationStatus.completed && mounted) {
        Navigator.of(context).maybePop();
      }
    });
    _controller.forward();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: () => Navigator.of(context).maybePop(),
      child: AnimatedBuilder(
        animation: _controller,
        builder: (_, _) => CustomPaint(
          painter: _TomatoBurstPainter(_controller.value),
          child: const SizedBox.expand(),
        ),
      ),
    );
  }
}

class _TomatoBurstPainter extends CustomPainter {
  final double t;
  _TomatoBurstPainter(this.t);

  static const _shardColors = [
    Color(0xFFE53935),
    Color(0xFFFF6B5B),
    Color(0xFFC62828),
    Color(0xFFFF8A80),
    Color(0xFFFFAB91),
  ];

  @override
  void paint(Canvas canvas, Size size) {
    final cx = size.width / 2;
    final cy = size.height / 2;
    final base = size.shortestSide;
    final R = base * 0.10;

    // 炸裂碎片
    if (t > 0.4) {
      final p = ((t - 0.4) / 0.6).clamp(0.0, 1.0);
      final eased = p * (2 - p); // 减速外飞
      final maxDist = base * 0.26;
      final gravity = base * 0.12 * p * p;
      const n = 14;
      for (var i = 0; i < n; i++) {
        final angle = (i / n) * 2 * pi + (i.isEven ? 0.12 : -0.08);
        final dist = maxDist * eased;
        final x = cx + cos(angle) * dist;
        final y = cy + sin(angle) * dist + gravity;
        final rad = R * 0.42 * (1 - p * 0.5);
        final alpha = (1 - p).clamp(0.0, 1.0);
        canvas.drawCircle(
          Offset(x, y),
          rad,
          Paint()
            ..color = _shardColors[i % _shardColors.length].withValues(
              alpha: alpha,
            ),
        );
      }
    }

    // 爆裂瞬间闪光环
    if (t > 0.38 && t < 0.7) {
      final fp = ((t - 0.38) / 0.32).clamp(0.0, 1.0);
      canvas.drawCircle(
        Offset(cx, cy),
        R * (1 + fp * 3.5),
        Paint()
          ..color = const Color(0xFFFFEB3B).withValues(alpha: (1 - fp) * 0.6)
          ..style = PaintingStyle.stroke
          ..strokeWidth = 3,
      );
    }

    // 番茄主体（0.45 前微胀，之后淡出）
    final bodyAlpha = t < 0.45 ? 1.0 : (1 - (t - 0.45) / 0.15).clamp(0.0, 1.0);
    if (bodyAlpha > 0) {
      final scale = 1 + (t < 0.45 ? t : 0.45) * 0.25;
      final rr = R * scale;
      // 主体
      canvas.drawCircle(
        Offset(cx, cy),
        rr,
        Paint()..color = const Color(0xFFE53935).withValues(alpha: bodyAlpha),
      );
      // 高光
      canvas.drawCircle(
        Offset(cx - rr * 0.3, cy - rr * 0.3),
        rr * 0.32,
        Paint()..color = Colors.white.withValues(alpha: 0.20 * bodyAlpha),
      );
      // 顶部绿色萼片（五角星）
      final sepalCenter = Offset(cx, cy - rr * 0.85);
      final sepalR = rr * 0.55;
      final path = Path();
      for (var i = 0; i < 10; i++) {
        final angle = -pi / 2 + i * pi / 5;
        final rad = i.isEven ? sepalR : sepalR * 0.45;
        final x = sepalCenter.dx + cos(angle) * rad;
        final y = sepalCenter.dy + sin(angle) * rad;
        if (i == 0) {
          path.moveTo(x, y);
        } else {
          path.lineTo(x, y);
        }
      }
      path.close();
      canvas.drawPath(
        path,
        Paint()..color = const Color(0xFF4CAF50).withValues(alpha: bodyAlpha),
      );
    }
  }

  @override
  bool shouldRepaint(_TomatoBurstPainter oldDelegate) => oldDelegate.t != t;
}
