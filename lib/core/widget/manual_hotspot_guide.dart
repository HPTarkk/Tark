import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../motion/app_motion.dart';
import '../theme/app_colors.dart';

/// Joining the other phone's hotspot by hand, told as a scene of its own.
///
/// What a move falls back to once Android has turned the automatic join down
/// more than once. A third silent retry would only fail the same way; the
/// Settings app never does. So the screen stops trying and shows the person
/// exactly what to do there: the steps in order, the one to do now lit and
/// walking forward, and the network's name and password ready to copy.
///
/// Every string comes in from the caller, which knows which phone this is
/// and whose hotspot it is. With reduced motion nothing walks or pulses: the
/// steps are all shown, still.
class ManualHotspotGuide extends StatefulWidget {
  const ManualHotspotGuide({
    required this.title,
    required this.detail,
    required this.steps,
    required this.networkLabel,
    required this.passwordLabel,
    required this.copiedLabel,
    this.ssid,
    this.password,
    this.actions = const [],
    super.key,
  });

  final String title;
  final String detail;

  /// In the order they are done.
  final List<String> steps;

  final String networkLabel;
  final String passwordLabel;
  final String copiedLabel;

  /// The network to pick, when it is known. Without it the card is left out.
  final String? ssid;
  final String? password;

  /// The ways forward, the primary first.
  final List<Widget> actions;

  /// How long each step stays lit before the next takes over.
  static const stepBeat = Duration(milliseconds: 1700);

  @override
  State<ManualHotspotGuide> createState() => _ManualHotspotGuideState();
}

class _ManualHotspotGuideState extends State<ManualHotspotGuide>
    with TickerProviderStateMixin {
  /// Plays once: the pieces arriving, top to bottom.
  late final AnimationController _arrive = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1100),
  );

  /// Loops: which step is lit, and the emblem's arcs.
  late final AnimationController _walk = AnimationController(
    vsync: this,
    duration: ManualHotspotGuide.stepBeat * math.max(1, widget.steps.length),
  );

  bool _still = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _still = AppMotion.reduced(context);
    if (_still) {
      _arrive.value = 1;
      _walk.stop();
    } else {
      if (_arrive.value == 0 && !_arrive.isAnimating) _arrive.forward();
      if (!_walk.isAnimating) _walk.repeat();
    }
  }

  @override
  void dispose() {
    _arrive.dispose();
    _walk.dispose();
    super.dispose();
  }

  /// Fades and rises piece [index] in on its turn.
  Widget _arriving(int index, Widget child) => AnimatedBuilder(
    animation: _arrive,
    child: child,
    builder: (context, child) {
      final start = math.min(0.7, index * 0.11);
      final t = ((_arrive.value - start) / 0.35).clamp(0.0, 1.0);
      final p = AppMotion.easeOut.transform(t);
      return Opacity(
        opacity: p,
        child: Transform.translate(
          offset: Offset(0, AppMotion.rise * 1.6 * (1 - p)),
          child: child,
        ),
      );
    },
  );

  @override
  Widget build(BuildContext context) {
    final ssid = widget.ssid;
    final password = widget.password;
    var piece = 0;
    return SingleChildScrollView(
      key: const Key('manual-hotspot-guide'),
      padding: const EdgeInsets.symmetric(vertical: 24),
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 440),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _arriving(
                piece++,
                Center(
                  child: _JoinByHandEmblem(loop: _walk, still: _still),
                ),
              ),
              const SizedBox(height: 22),
              _arriving(
                piece++,
                Text(
                  widget.title,
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    color: AppColors.textPrimary,
                    fontSize: 20,
                    fontWeight: FontWeight.w800,
                    height: 1.25,
                  ),
                ),
              ),
              const SizedBox(height: 8),
              _arriving(
                piece++,
                Text(
                  widget.detail,
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    color: AppColors.textSecondary,
                    fontSize: 13.5,
                    height: 1.5,
                  ),
                ),
              ),
              const SizedBox(height: 22),
              for (final (i, step) in widget.steps.indexed)
                _arriving(
                  piece++,
                  _StepRow(
                    number: i + 1,
                    text: step,
                    walk: _walk,
                    index: i,
                    count: widget.steps.length,
                    still: _still,
                    last: i == widget.steps.length - 1,
                  ),
                ),
              if (ssid != null) ...[
                const SizedBox(height: 16),
                _arriving(
                  piece++,
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    decoration: BoxDecoration(
                      color: AppColors.card,
                      borderRadius: BorderRadius.circular(16),
                      border: Border.all(color: AppColors.border),
                    ),
                    child: Column(
                      children: [
                        _CopyRow(
                          key: const Key('manual-hotspot-ssid'),
                          label: widget.networkLabel,
                          value: ssid,
                          copiedLabel: widget.copiedLabel,
                        ),
                        if (password != null && password.isNotEmpty) ...[
                          Divider(color: AppColors.border, height: 1),
                          _CopyRow(
                            key: const Key('manual-hotspot-password'),
                            label: widget.passwordLabel,
                            value: password,
                            copiedLabel: widget.copiedLabel,
                          ),
                        ],
                      ],
                    ),
                  ),
                ),
              ],
              if (widget.actions.isNotEmpty) ...[
                const SizedBox(height: 22),
                for (final action in widget.actions)
                  _arriving(
                    piece++,
                    Padding(
                      padding: const EdgeInsets.only(bottom: 10),
                      child: action,
                    ),
                  ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

/// One numbered step. Lit while it is the one to do; the line under it
/// fills as the walk moves past it to the next.
class _StepRow extends StatelessWidget {
  const _StepRow({
    required this.number,
    required this.text,
    required this.walk,
    required this.index,
    required this.count,
    required this.still,
    required this.last,
  });

  final int number;
  final String text;
  final Animation<double> walk;
  final int index;
  final int count;
  final bool still;
  final bool last;

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: walk,
      builder: (context, _) {
        final position = walk.value * count;
        // 0 → 1 across this step's beat, rising quickly and easing off.
        final local = still ? 0.0 : (position - index).clamp(0.0, 1.0);
        final lit = still || (position >= index && position < index + 1);
        final glow = lit && !still ? math.sin(local * math.pi) : 0.0;
        final passed = still || position >= index + 1;
        final color = lit ? AppColors.amber : AppColors.textSecondary;
        final fill = !last && (still || passed)
            ? 1.0
            : lit
            ? Curves.easeInOut.transform(local)
            : 0.0;
        return CustomPaint(
          // The line down to the next step, drawn under the row rather than
          // laid out in it, so the row sizes to its words alone.
          painter: last
              ? null
              : _ConnectorPainter(
                  fill: fill,
                  rtl: Directionality.of(context) == TextDirection.rtl,
                  track: AppColors.border,
                  lit: AppColors.amber.withValues(alpha: 0.75),
                ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SizedBox(
                width: 34,
                child: Center(
                  child: Container(
                    width: 30,
                    height: 30,
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: lit
                          ? Color.alphaBlend(
                              AppColors.amber.withValues(alpha: 0.18),
                              AppColors.card,
                            )
                          : AppColors.card,
                      border: Border.all(
                        color: lit ? AppColors.amber : AppColors.border,
                        width: lit ? 2 : 1.2,
                      ),
                      boxShadow: [
                        if (glow > 0)
                          BoxShadow(
                            color: AppColors.amber.withValues(
                              alpha: 0.45 * glow,
                            ),
                            blurRadius: 14 * glow,
                            spreadRadius: 1.5 * glow,
                          ),
                      ],
                    ),
                    child: Text(
                      '$number',
                      style: TextStyle(
                        color: color,
                        fontWeight: FontWeight.w800,
                        fontSize: 13,
                      ),
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Padding(
                  padding: EdgeInsets.only(top: 5, bottom: last ? 0 : 20),
                  child: AnimatedDefaultTextStyle(
                    duration: AppMotion.card,
                    style: TextStyle(
                      color: lit
                          ? AppColors.textPrimary
                          : AppColors.textSecondary,
                      fontSize: 14,
                      fontWeight: lit ? FontWeight.w700 : FontWeight.w500,
                      height: 1.4,
                    ),
                    child: Text(text),
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

/// The line from one step's number down to the next, [fill] of it lit.
class _ConnectorPainter extends CustomPainter {
  const _ConnectorPainter({
    required this.fill,
    required this.rtl,
    required this.track,
    required this.lit,
  });

  final double fill;
  final bool rtl;
  final Color track;
  final Color lit;

  @override
  void paint(Canvas canvas, Size size) {
    final x = rtl ? size.width - 17 : 17.0;
    const top = 34.0;
    final bottom = size.height - 2;
    if (bottom <= top) return;
    final paint = Paint()
      ..strokeWidth = 2
      ..strokeCap = StrokeCap.round;
    canvas.drawLine(Offset(x, top), Offset(x, bottom), paint..color = track);
    final reach = fill.clamp(0.0, 1.0);
    if (reach > 0) {
      canvas.drawLine(
        Offset(x, top),
        Offset(x, top + (bottom - top) * reach),
        paint..color = lit,
      );
    }
  }

  @override
  bool shouldRepaint(_ConnectorPainter old) =>
      old.fill != fill ||
      old.rtl != rtl ||
      old.track != track ||
      old.lit != lit;
}

/// A name or password with a copy button that answers with a tick.
class _CopyRow extends StatefulWidget {
  const _CopyRow({
    required this.label,
    required this.value,
    required this.copiedLabel,
    super.key,
  });

  final String label;
  final String value;
  final String copiedLabel;

  @override
  State<_CopyRow> createState() => _CopyRowState();
}

class _CopyRowState extends State<_CopyRow> {
  bool _copied = false;
  Timer? _reset;

  Future<void> _copy() async {
    await Clipboard.setData(ClipboardData(text: widget.value));
    if (!mounted) return;
    unawaited(HapticFeedback.selectionClick());
    setState(() => _copied = true);
    _reset?.cancel();
    _reset = Timer(const Duration(milliseconds: 1600), () {
      if (mounted) setState(() => _copied = false);
    });
  }

  @override
  void dispose() {
    _reset?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 10),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  widget.label,
                  style: TextStyle(
                    color: AppColors.textSecondary,
                    fontSize: 10.5,
                    fontWeight: FontWeight.w800,
                    letterSpacing: 1.2,
                  ),
                ),
                const SizedBox(height: 4),
                SelectableText(
                  widget.value,
                  style: TextStyle(
                    color: AppColors.textPrimary,
                    fontSize: 16,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 0.3,
                  ),
                ),
              ],
            ),
          ),
          Tooltip(
            message: widget.copiedLabel,
            child: IconButton(
              onPressed: _copy,
              icon: AnimatedSwitcher(
                duration: AppMotion.card,
                transitionBuilder: (child, animation) =>
                    ScaleTransition(scale: animation, child: child),
                child: _copied
                    ? Icon(
                        Icons.check_rounded,
                        key: const ValueKey('copied'),
                        color: AppColors.green,
                      )
                    : Icon(
                        Icons.copy_rounded,
                        key: const ValueKey('copy'),
                        color: AppColors.textSecondary,
                        size: 20,
                      ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// A phone under a Wi-Fi fan whose arcs light one after another, with a tap
/// rippling on its screen: "pick the network yourself", drawn.
class _JoinByHandEmblem extends StatelessWidget {
  const _JoinByHandEmblem({required this.loop, required this.still});

  final Animation<double> loop;
  final bool still;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 120,
      height: 112,
      child: AnimatedBuilder(
        animation: loop,
        builder: (context, _) => CustomPaint(
          painter: _JoinByHandPainter(
            // A shorter cycle than the step walk, so the emblem breathes.
            t: still ? 1 : (loop.value * 3) % 1,
            still: still,
            accent: AppColors.amber,
            line: AppColors.textSecondary,
            card: AppColors.card,
          ),
        ),
      ),
    );
  }
}

class _JoinByHandPainter extends CustomPainter {
  const _JoinByHandPainter({
    required this.t,
    required this.still,
    required this.accent,
    required this.line,
    required this.card,
  });

  final double t;
  final bool still;
  final Color accent;
  final Color line;
  final Color card;

  @override
  void paint(Canvas canvas, Size size) {
    final cx = size.width / 2;
    // The phone.
    final phone = RRect.fromRectAndRadius(
      Rect.fromCenter(
        center: Offset(cx, size.height * 0.68),
        width: 44,
        height: 66,
      ),
      const Radius.circular(9),
    );
    canvas.drawRRect(phone, Paint()..color = card);
    canvas.drawRRect(
      phone,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2
        ..color = line.withValues(alpha: 0.8),
    );

    // The fan above it: three arcs lighting in turn, then the dot.
    final origin = Offset(cx, size.height * 0.5);
    for (var i = 0; i < 3; i++) {
      final radius = 18.0 + i * 13;
      final on = still ? 1.0 : ((t * 4) - i).clamp(0.0, 1.0);
      canvas.drawArc(
        Rect.fromCircle(center: origin, radius: radius),
        -math.pi * 0.78,
        math.pi * 0.56,
        false,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeCap = StrokeCap.round
          ..strokeWidth = 4
          ..color = Color.lerp(line.withValues(alpha: 0.25), accent, on)!,
      );
    }

    // The tap on the screen, late in each cycle.
    final tap = still ? 0.0 : ((t - 0.62) / 0.38).clamp(0.0, 1.0);
    final tapAt = Offset(cx, phone.center.dy + 6);
    canvas.drawCircle(
      tapAt,
      4,
      Paint()..color = accent.withValues(alpha: still ? 0.9 : 0.5 + 0.5 * tap),
    );
    if (tap > 0) {
      canvas.drawCircle(
        tapAt,
        4 + 14 * tap,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2
          ..color = accent.withValues(alpha: 0.7 * (1 - tap)),
      );
    }
  }

  @override
  bool shouldRepaint(_JoinByHandPainter old) =>
      old.t != t ||
      old.still != still ||
      old.accent != accent ||
      old.line != line ||
      old.card != card;
}
