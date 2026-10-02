import 'dart:async';
import 'dart:math';
import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../../../core/diagnostics/screen_log.dart';
import '../../../../core/l10n/extension.dart';
import '../../../../core/motion/app_motion.dart';
import '../../../../core/theme/app_colors.dart';
import '../../../../core/utils/extensions.dart';
import '../../../../core/utils/logger.dart';
import '../../../room/api/room_api.dart';
import '../manager/walkie_talkie_cubit.dart';

/// Leaves a Room's call by itself once this phone has been alone in it for
/// [aloneLimit], so a phone whose people never came back does not hold its
/// connection (and, when it shares one, its Wi-Fi) open all day.
///
/// For the last [countdown] it takes over the screen with a big count and a
/// "Stay longer" button, which starts the wait over. Anyone coming back while
/// it counts closes it on its own.
///
/// Rooms only: it does nothing outside a [RoomConnectionStatusScope]. Time is
/// kept with timers rather than frames, because the call carries on with the
/// screen off and frames stop there.
class RoomAloneGuard extends StatefulWidget {
  const RoomAloneGuard({
    required this.onLeave,
    this.aloneLimit = defaultAloneLimit,
    this.countdown = defaultCountdown,
    this.inRoom,
    super.key,
  });

  static const defaultAloneLimit = Duration(minutes: 10);
  static const defaultCountdown = Duration(seconds: 60);

  /// Ends the call, the same way the Leave button does.
  final VoidCallback onLeave;

  /// From the moment nobody else is heard until the call ends, countdown
  /// included.
  final Duration aloneLimit;
  final Duration countdown;

  /// Overrides the Room check; tests have no live Room scope to sit in.
  @visibleForTesting
  final bool? inRoom;

  @override
  State<RoomAloneGuard> createState() => _RoomAloneGuardState();
}

class _RoomAloneGuardState extends State<RoomAloneGuard>
    with TickerProviderStateMixin {
  /// The whole overlay coming in and going out.
  late final AnimationController _shown = AnimationController(
    vsync: this,
    duration: AppMotion.sheet,
    reverseDuration: AppMotion.card,
  );

  /// The ring around the count, 0 (full) to 1 (empty).
  late final AnimationController _drain = AnimationController(vsync: this);

  Timer? _warnTimer;
  Timer? _tick;
  bool _alone = false;
  int _secondsLeft = 0;
  bool _left = false;

  bool get _counting => _tick != null;

  bool _inRoom(BuildContext context) =>
      widget.inRoom ?? RoomConnectionStatusScope.maybeOf(context) != null;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _onAlone(context.read<WalkieTalkieCubit>().state.activeUsers.isEmpty);
  }

  void _onAlone(bool alone) {
    if (!_inRoom(context)) {
      _alone = false;
      _reset();
      return;
    }
    if (alone == _alone) return;
    _alone = alone;
    if (alone) {
      _arm();
    } else {
      // Someone is back: whatever was counting stops, and the wait starts
      // from zero next time.
      _reset();
    }
  }

  void _arm() {
    _warnTimer?.cancel();
    final wait = widget.aloneLimit - widget.countdown;
    Logger.diagnostic(
      'room: alone, leaving in ${widget.aloneLimit.inSeconds}s',
    );
    _warnTimer = Timer(wait.isNegative ? Duration.zero : wait, _startCountdown);
  }

  void _startCountdown() {
    if (!mounted || !_alone) return;
    Logger.diagnostic('room: alone countdown');
    HapticFeedback.mediumImpact();
    setState(() => _secondsLeft = widget.countdown.inSeconds);
    _drain.value = 0;
    _drainTo(1 / max(1, _secondsLeft));
    _shown.forward();
    _tick = Timer.periodic(const Duration(seconds: 1), (_) => _onTick());
  }

  void _onTick() {
    if (!mounted) return;
    final next = _secondsLeft - 1;
    if (next <= 0) {
      _leave();
      return;
    }
    if (next <= 5) HapticFeedback.selectionClick();
    setState(() => _secondsLeft = next);
    final total = max(1, widget.countdown.inSeconds);
    _drainTo((total - next + 1) / total);
  }

  /// Eases the ring to where it should be one second from now, so it drains
  /// smoothly and stays in step with the count even after the screen was off.
  void _drainTo(double target) {
    _drain.animateTo(
      target.clamp(0, 1),
      duration: const Duration(seconds: 1),
      curve: Curves.linear,
    );
  }

  void _stopCounting() {
    _tick?.cancel();
    _tick = null;
    _drain.stop();
  }

  void _reset() {
    _warnTimer?.cancel();
    _warnTimer = null;
    if (_counting) {
      _stopCounting();
      _shown.reverse();
    }
  }

  void _stayLonger() {
    ScreenLog.tap('AloneStay');
    HapticFeedback.lightImpact();
    _stopCounting();
    _shown.reverse();
    if (_alone) _arm();
  }

  void _leave() {
    if (_left) return;
    _left = true;
    Logger.diagnostic('room: alone, leaving');
    _stopCounting();
    _warnTimer?.cancel();
    widget.onLeave();
  }

  @override
  void dispose() {
    _warnTimer?.cancel();
    _tick?.cancel();
    _shown.dispose();
    _drain.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return BlocListener<WalkieTalkieCubit, WalkieTalkieState>(
      listenWhen: (previous, current) =>
          previous.activeUsers.isEmpty != current.activeUsers.isEmpty,
      listener: (context, state) => _onAlone(state.activeUsers.isEmpty),
      child: AnimatedBuilder(
        animation: _shown,
        builder: (context, child) {
          if (_shown.isDismissed) return const SizedBox.shrink();
          return IgnorePointer(
            ignoring: _shown.status == AnimationStatus.reverse,
            child: child,
          );
        },
        child: _Overlay(
          shown: _shown,
          drain: _drain,
          secondsLeft: _secondsLeft,
          minutes: widget.aloneLimit.inMinutes,
          onStay: _stayLonger,
          onLeave: () {
            ScreenLog.tap('AloneLeaveNow');
            _leave();
          },
        ),
      ),
    );
  }
}

class _Overlay extends StatelessWidget {
  const _Overlay({
    required this.shown,
    required this.drain,
    required this.secondsLeft,
    required this.minutes,
    required this.onStay,
    required this.onLeave,
  });

  final Animation<double> shown;
  final Animation<double> drain;
  final int secondsLeft;
  final int minutes;
  final VoidCallback onStay;
  final VoidCallback onLeave;

  @override
  Widget build(BuildContext context) {
    final s = context.getString;
    final reduced = AppMotion.reduced(context);
    final fade = CurvedAnimation(
      parent: shown,
      curve: AppMotion.easeOut,
      reverseCurve: AppMotion.leaving,
    );
    final column = Padding(
      padding: const EdgeInsets.fromLTRB(24, 24, 24, 20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Spacer(flex: 3),
          Text(
            s.alone_leaving_in,
            textAlign: TextAlign.center,
            style: TextStyle(
              color: AppColors.textSecondary,
              fontSize: 15,
              fontWeight: FontWeight.w700,
              letterSpacing: 0.4,
            ),
          ),
          const SizedBox(height: 24),
          Center(
            child: _CountdownDial(
              drain: drain,
              secondsLeft: secondsLeft,
              unit: s.alone_seconds,
            ),
          ),
          const SizedBox(height: 28),
          Text(
            s.alone_body(minutes.localized(context)),
            textAlign: TextAlign.center,
            style: TextStyle(
              color: AppColors.textPrimary,
              fontSize: 16,
              height: 1.5,
              fontWeight: FontWeight.w600,
            ),
          ),
          const Spacer(flex: 4),
          PulseGlow(
            borderRadius: BorderRadius.circular(16),
            child: _StayButton(label: s.alone_stay, onTap: onStay),
          ),
          const SizedBox(height: 8),
          TextButton(
            key: const Key('room-alone-leave-now'),
            onPressed: onLeave,
            style: TextButton.styleFrom(
              foregroundColor: AppColors.red,
              padding: const EdgeInsets.symmetric(vertical: 14),
            ),
            child: Text(
              s.alone_leave_now,
              style: const TextStyle(fontWeight: FontWeight.w700),
            ),
          ),
        ],
      ),
    );
    // Spread out on a tall screen, scrollable on a short one with large text.
    final content = LayoutBuilder(
      builder: (context, constraints) => SingleChildScrollView(
        child: ConstrainedBox(
          constraints: BoxConstraints(minHeight: constraints.maxHeight),
          child: IntrinsicHeight(child: column),
        ),
      ),
    );
    return FadeTransition(
      opacity: fade,
      child: Material(
        key: const Key('room-alone-countdown'),
        type: MaterialType.transparency,
        child: Stack(
          fit: StackFit.expand,
          children: [
            BackdropFilter(
              filter: ImageFilter.blur(sigmaX: 14, sigmaY: 14),
              child: ColoredBox(
                color: AppColors.background.withValues(alpha: 0.88),
              ),
            ),
            SafeArea(
              child: reduced
                  ? content
                  : ScaleTransition(
                      scale: Tween<double>(begin: 0.96, end: 1).animate(fade),
                      child: content,
                    ),
            ),
          ],
        ),
      ),
    );
  }
}

/// The count, in a ring that drains as it falls. The last ten seconds turn
/// from amber to red.
class _CountdownDial extends StatelessWidget {
  const _CountdownDial({
    required this.drain,
    required this.secondsLeft,
    required this.unit,
  });

  static const double _size = 220;

  final Animation<double> drain;
  final int secondsLeft;
  final String unit;

  @override
  Widget build(BuildContext context) {
    final urgent = secondsLeft <= 10;
    final accent = urgent ? AppColors.red : AppColors.amber;
    final reduced = AppMotion.reduced(context);
    return Semantics(
      liveRegion: true,
      label: '${secondsLeft.localized(context)} $unit',
      child: SizedBox.square(
        dimension: _size,
        child: Stack(
          alignment: Alignment.center,
          children: [
            RepaintBoundary(
              child: TweenAnimationBuilder<Color?>(
                tween: ColorTween(end: accent),
                duration: AppMotion.card,
                curve: AppMotion.easeOut,
                builder: (context, color, _) => CustomPaint(
                  size: const Size.square(_size),
                  painter: _RingPainter(
                    drain: drain,
                    color: color ?? accent,
                    track: AppColors.border,
                  ),
                ),
              ),
            ),
            // Large text shrinks to fit inside the ring rather than spilling
            // over it.
            Padding(
              padding: const EdgeInsets.all(28),
              child: FittedBox(
                fit: BoxFit.scaleDown,
                child: ExcludeSemantics(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      AnimatedSwitcher(
                        duration: AppMotion.card,
                        switchInCurve: AppMotion.easeOut,
                        switchOutCurve: AppMotion.leaving,
                        transitionBuilder: (child, animation) {
                          final fade = FadeTransition(
                            opacity: animation,
                            child: child,
                          );
                          if (reduced) return fade;
                          // The new number rises in from below as the old one
                          // leaves upward: a count, not a flicker.
                          final incoming =
                              child.key == ValueKey<int>(secondsLeft);
                          return SlideTransition(
                            position: Tween<Offset>(
                              begin: Offset(0, incoming ? 0.35 : -0.35),
                              end: Offset.zero,
                            ).animate(animation),
                            child: fade,
                          );
                        },
                        child: Text(
                          secondsLeft.localized(context),
                          key: ValueKey<int>(secondsLeft),
                          style: TextStyle(
                            color: urgent
                                ? AppColors.red
                                : AppColors.textPrimary,
                            fontSize: 84,
                            height: 1,
                            fontWeight: FontWeight.w800,
                            fontFeatures: const [FontFeature.tabularFigures()],
                          ),
                        ),
                      ),
                      const SizedBox(height: 6),
                      Text(
                        unit,
                        style: TextStyle(
                          color: AppColors.textSecondary,
                          fontSize: 14,
                          fontWeight: FontWeight.w600,
                        ),
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

class _RingPainter extends CustomPainter {
  _RingPainter({required this.drain, required this.color, required this.track})
    : super(repaint: drain);

  final Animation<double> drain;
  final Color color;
  final Color track;

  static const double _stroke = 8;

  @override
  void paint(Canvas canvas, Size size) {
    final rect = (Offset.zero & size).deflate(_stroke / 2);
    canvas.drawArc(
      rect,
      0,
      2 * pi,
      false,
      Paint()
        ..color = track
        ..style = PaintingStyle.stroke
        ..strokeWidth = _stroke,
    );
    final remaining = (1 - drain.value).clamp(0.0, 1.0);
    if (remaining == 0) return;
    canvas.drawArc(
      rect,
      -pi / 2,
      2 * pi * remaining,
      false,
      Paint()
        ..color = color
        ..style = PaintingStyle.stroke
        ..strokeCap = StrokeCap.round
        ..strokeWidth = _stroke,
    );
  }

  @override
  bool shouldRepaint(_RingPainter oldDelegate) =>
      oldDelegate.color != color || oldDelegate.track != track;
}

class _StayButton extends StatelessWidget {
  const _StayButton({required this.label, required this.onTap});

  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Semantics(
    button: true,
    label: label,
    child: PressableScale(
      key: const Key('room-alone-stay'),
      onTap: onTap,
      borderRadius: BorderRadius.circular(16),
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: AppColors.amber,
          borderRadius: BorderRadius.circular(16),
        ),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 17),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(Icons.timer_outlined, size: 20, color: AppColors.background),
              const SizedBox(width: 8),
              Flexible(
                child: Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: AppColors.background,
                    fontSize: 16,
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    ),
  );
}
