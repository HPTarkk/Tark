import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../../core/motion/app_motion.dart';
import '../../../../core/theme/app_colors.dart';

/// The glyph at the top of every account screen, and the one place the
/// screen's state shows at a glance.
///
/// - **Arriving:** scales up from just under full size while two rings leave
///   it, once, like the signal rings on the Wi-Fi page.
/// - **Busy:** a short arc circles it while a request is out.
/// - **Refused:** a small sideways shake, the way a lock refuses a wrong key.
/// - **Done:** turns green, the glyph gives way to a check mark (the one
///   element allowed to overshoot) and a ring bursts out. [onSuccessShown]
///   fires once that beat has played, which is when the screen leaves.
///
/// Floor-device budget: one painter driven through `repaint:`, strokes only,
/// no blur masks or clipping. The only repeating controller is the busy arc,
/// and it runs only while a request is out and full motion is allowed.
class AuthHero extends StatefulWidget {
  const AuthHero({
    required this.icon,
    required this.color,
    this.busy = false,
    this.error,
    this.success = false,
    this.onSuccessShown,
    super.key,
  });

  final IconData icon;
  final Color color;
  final bool busy;

  /// The current refusal. A new non-null value shakes the hero once.
  final Object? error;
  final bool success;
  final VoidCallback? onSuccessShown;

  static const double size = 136;
  static const double core = 76;

  @override
  State<AuthHero> createState() => _AuthHeroState();
}

class _AuthHeroState extends State<AuthHero> with TickerProviderStateMixin {
  late final AnimationController _in = AnimationController(
    vsync: this,
    duration: AppMotion.sheet * 2.5,
  )..forward();

  late final AnimationController _spin = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1100),
  );

  /// How much of the busy arc shows, so it fades in and out rather than
  /// popping.
  late final AnimationController _busy = AnimationController(
    vsync: this,
    duration: AppMotion.card,
    value: widget.busy ? 1 : 0,
  );

  late final AnimationController _shake = AnimationController(
    vsync: this,
    duration: AppMotion.entrance + AppMotion.press,
  );

  late final AnimationController _success = AnimationController(
    vsync: this,
    duration: AppMotion.successBeat,
  )..addStatusListener(_onSuccessStatus);

  @override
  void initState() {
    super.initState();
    if (widget.success) _success.forward();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _syncSpin();
  }

  @override
  void didUpdateWidget(AuthHero oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.busy != oldWidget.busy) {
      if (widget.busy) {
        _busy.forward();
      } else {
        _busy.reverse();
      }
      _syncSpin();
    }
    if (widget.error != null && widget.error != oldWidget.error) {
      if (!AppMotion.reduced(context)) _shake.forward(from: 0);
      HapticFeedback.lightImpact();
    }
    if (widget.success && !oldWidget.success) {
      HapticFeedback.mediumImpact();
      _success.forward(from: 0);
    }
  }

  void _onSuccessStatus(AnimationStatus status) {
    if (status == AnimationStatus.completed) widget.onSuccessShown?.call();
  }

  /// The arc only turns while a request is out, and never under reduced
  /// motion, where it holds still and keeps only its fade.
  void _syncSpin() {
    if (widget.busy && !AppMotion.reduced(context)) {
      if (!_spin.isAnimating) _spin.repeat();
    } else if (_spin.isAnimating) {
      _spin.stop();
    }
  }

  @override
  void dispose() {
    _in.dispose();
    _spin.dispose();
    _busy.dispose();
    _shake.dispose();
    _success.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final reduced = AppMotion.reduced(context);
    final arrive = CurvedAnimation(
      parent: _in,
      curve: const Interval(0, 0.6, curve: AppMotion.easeOut),
    );
    final done = CurvedAnimation(
      parent: _success,
      curve: const Interval(0, 0.45, curve: AppMotion.easeOut),
    );
    final green = AppColors.green;

    Widget hero = SizedBox(
      width: AuthHero.size,
      height: AuthHero.size,
      child: Stack(
        alignment: Alignment.center,
        children: [
          Positioned.fill(
            child: CustomPaint(
              painter: _HeroPainter(
                arrive: _in,
                spin: _spin,
                busy: _busy,
                success: _success,
                color: widget.color,
                green: green,
                coreRadius: AuthHero.core / 2,
                travel: !reduced,
              ),
            ),
          ),
          AnimatedBuilder(
            animation: done,
            builder: (context, child) {
              final c = Color.lerp(widget.color, green, done.value)!;
              return Container(
                width: AuthHero.core,
                height: AuthHero.core,
                decoration: BoxDecoration(
                  color: AppColors.card,
                  shape: BoxShape.circle,
                  border: Border.all(
                    color: c.withValues(alpha: 0.85),
                    width: 2,
                  ),
                  boxShadow: [
                    BoxShadow(
                      color: c.withValues(alpha: 0.26),
                      blurRadius: 24,
                      spreadRadius: 1,
                    ),
                  ],
                ),
                child: child,
              );
            },
            child: _Glyph(
              icon: widget.icon,
              color: widget.color,
              green: green,
              success: _success,
            ),
          ),
        ],
      ),
    );

    hero = AnimatedBuilder(
      animation: _shake,
      child: hero,
      builder: (context, child) {
        final t = _shake.value;
        // Three swings that die away; symmetric, so it reads the same in
        // either direction of writing.
        final dx = math.sin(t * math.pi * 6) * 7 * (1 - t);
        return Transform.translate(offset: Offset(dx, 0), child: child);
      },
    );

    final faded = FadeTransition(opacity: arrive, child: hero);
    return RepaintBoundary(
      child: reduced
          ? faded
          : ScaleTransition(
              scale: Tween<double>(begin: 0.86, end: 1).animate(arrive),
              child: faded,
            ),
    );
  }
}

/// The screen's glyph, giving way to a check mark once the flow is done.
class _Glyph extends StatelessWidget {
  const _Glyph({
    required this.icon,
    required this.color,
    required this.green,
    required this.success,
  });

  final IconData icon;
  final Color color;
  final Color green;
  final Animation<double> success;

  @override
  Widget build(BuildContext context) {
    final out = CurvedAnimation(
      parent: success,
      curve: const Interval(0.05, 0.3, curve: AppMotion.easeOut),
    );
    final check = CurvedAnimation(
      parent: success,
      curve: const Interval(0.2, 0.7, curve: Curves.easeOutBack),
    );
    return Stack(
      alignment: Alignment.center,
      children: [
        FadeTransition(
          opacity: ReverseAnimation(out),
          child: ScaleTransition(
            scale: Tween<double>(begin: 1, end: 0.6).animate(out),
            child: Icon(icon, color: color, size: 34),
          ),
        ),
        FadeTransition(
          opacity: CurvedAnimation(
            parent: success,
            curve: const Interval(0.2, 0.45),
          ),
          child: ScaleTransition(
            scale: Tween<double>(begin: 0.4, end: 1).animate(check),
            child: Icon(Icons.check_rounded, color: green, size: 40),
          ),
        ),
      ],
    );
  }
}

class _HeroPainter extends CustomPainter {
  _HeroPainter({
    required this.arrive,
    required this.spin,
    required this.busy,
    required this.success,
    required this.color,
    required this.green,
    required this.coreRadius,
    required this.travel,
  }) : super(repaint: Listenable.merge([arrive, spin, busy, success]));

  final Animation<double> arrive;
  final Animation<double> spin;
  final Animation<double> busy;
  final Animation<double> success;
  final Color color;
  final Color green;
  final double coreRadius;

  /// False under reduced motion: rings fade in place instead of travelling.
  final bool travel;

  @override
  void paint(Canvas canvas, Size size) {
    final centre = size.center(Offset.zero);
    final maxRadius = size.shortestSide / 2 - 2;
    final done = AppMotion.easeOut.transform(
      (success.value / 0.45).clamp(0.0, 1.0),
    );
    final tone = Color.lerp(color, green, done)!;
    final haloRadius = coreRadius + 13;

    // A still halo the hero rests in.
    final settle = AppMotion.easeOut.transform(arrive.value);
    canvas.drawCircle(
      centre,
      haloRadius,
      Paint()
        ..color = tone.withValues(alpha: 0.16 * settle)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.2,
    );

    // Two rings leaving the glyph as the screen arrives, a beat apart.
    if (arrive.value < 1) {
      for (var i = 0; i < 2; i++) {
        final start = 0.12 + i * 0.18;
        final p = ((arrive.value - start) / (1 - start)).clamp(0.0, 1.0);
        if (p <= 0 || p >= 1) continue;
        final eased = AppMotion.easeOut.transform(p);
        final radius = travel
            ? coreRadius + (maxRadius - coreRadius) * eased
            : haloRadius;
        canvas.drawCircle(
          centre,
          radius,
          Paint()
            ..color = tone.withValues(alpha: 0.42 * (1 - p))
            ..style = PaintingStyle.stroke
            ..strokeWidth = 2,
        );
      }
    }

    // The busy arc, riding the halo.
    if (busy.value > 0) {
      final rect = Rect.fromCircle(center: centre, radius: haloRadius);
      final turn = spin.value * math.pi * 2;
      canvas.drawArc(
        rect,
        turn - math.pi / 2,
        math.pi * 0.55,
        false,
        Paint()
          ..color = tone.withValues(alpha: 0.9 * busy.value)
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2.6
          ..strokeCap = StrokeCap.round,
      );
    }

    // The success burst: one green ring out to the edge.
    final burst = ((success.value - 0.15) / 0.6).clamp(0.0, 1.0);
    if (burst > 0 && burst < 1) {
      final eased = AppMotion.easeOut.transform(burst);
      canvas.drawCircle(
        centre,
        travel ? coreRadius + (maxRadius - coreRadius) * eased : haloRadius,
        Paint()
          ..color = green.withValues(alpha: 0.6 * (1 - burst))
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2.4,
      );
    }
  }

  @override
  bool shouldRepaint(_HeroPainter old) =>
      old.color != color ||
      old.green != green ||
      old.coreRadius != coreRadius ||
      old.travel != travel;
}
