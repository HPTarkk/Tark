import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../../core/l10n/extension.dart';
import '../../../../core/motion/app_motion.dart';
import '../../../../core/theme/app_colors.dart';
import '../../domain/service/room_carrier_migration.dart';

/// The screen two phones see while they leave a shared router for one phone's
/// own hotspot, before their channel opens.
///
/// One scene, six beats. The drawing is the explanation: a router above two
/// phones, both hanging off it; a crown that settles on whichever phone will
/// lead; that phone's own signal rising; the other phone's line to the router
/// letting go and a direct line drawing across; packets checking it both
/// ways; and the router fading out once the phones no longer need it. Below
/// it, a rail of the same six steps, so it is always clear how far along it
/// is and that it is still moving.
///
/// Driven entirely by [progress]. Every step change plays its own entrance,
/// never backwards; with reduced motion the scene jumps straight to each pose
/// and holds still.
///
/// When the move does not finish, [failure] is told in the same scene rather
/// than on another screen: the beam between the phones snaps, the hotspot's
/// signal runs down and the rail stops where it got to, and the way forward
/// rises in under the words. Clearing it (Try again) plays the same motion
/// back, so failure, retry and progress are one continuous object.
///
/// [fellBack] is for a call that is already running: it landed on the house
/// Wi-Fi (or fell back to it when a hotspot dropped), and the first beat says
/// so instead of announcing that the phones have found each other.
class RoomCarrierMigrationView extends StatefulWidget {
  const RoomCarrierMigrationView({
    required this.progress,
    required this.peerName,
    this.caption,
    this.onEstablished,
    this.onStay,
    this.stayAfter = const Duration(seconds: 12),
    this.failure,
    this.actions = const [],
    this.fellBack = false,
    super.key,
  });

  final RoomMigrationProgress progress;

  /// What went wrong, in the person's words, or null while it is going.
  final RoomMigrationFailureCopy? failure;

  /// The ways forward under a [failure], the primary first.
  final List<Widget> actions;

  /// The channel is already open, on the house Wi-Fi.
  final bool fellBack;

  /// What the other phone's person is called, for the lines that name them.
  final String peerName;

  /// Small caps over the scene, e.g. the Room's name.
  final String? caption;

  /// Called once the established beat has landed, so the owner can open the
  /// channel out of it rather than over it.
  final VoidCallback? onEstablished;

  /// "Stay on this Wi-Fi instead". Offered only once a step has been on
  /// screen for [stayAfter]: a move that is going well should not be
  /// second-guessed, and one that is not must never leave the person with
  /// nothing to tap.
  final VoidCallback? onStay;
  final Duration stayAfter;

  /// How long the established beat holds before [onEstablished] fires.
  static const establishedBeat = Duration(milliseconds: 1250);

  @override
  State<RoomCarrierMigrationView> createState() =>
      _RoomCarrierMigrationViewState();
}

/// A failure, as the migration screen tells it.
@immutable
class RoomMigrationFailureCopy {
  const RoomMigrationFailureCopy({required this.title, required this.detail});

  final String title;
  final String detail;
}

class _RoomCarrierMigrationViewState extends State<RoomCarrierMigrationView>
    with TickerProviderStateMixin {
  /// 0→1 as the move falters into its failure; back to 0 on Try again.
  late final AnimationController _fail = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 950),
    value: widget.failure == null ? 0 : 1,
  );

  /// 0→1 each time the step changes: the transition into that step.
  late final AnimationController _enter = AnimationController(vsync: this);

  /// Ambient motion within a step: packets, pulses, the electing sweep.
  late final AnimationController _loop = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 2200),
  );

  late RoomMigrationStep _from = widget.progress.step;
  Timer? _establishedTimer;
  Timer? _stayTimer;
  bool _stayOffered = false;
  bool _started = false;

  static Duration _durationOf(RoomMigrationStep step) => switch (step) {
    RoomMigrationStep.found => const Duration(milliseconds: 700),
    RoomMigrationStep.electing => const Duration(milliseconds: 620),
    RoomMigrationStep.preparing => const Duration(milliseconds: 760),
    RoomMigrationStep.moving => const Duration(milliseconds: 900),
    RoomMigrationStep.verifying => const Duration(milliseconds: 520),
    RoomMigrationStep.established => const Duration(milliseconds: 1000),
  };

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_started) return;
    _started = true;
    _loop.loopUnlessReduced(context);
    _run(widget.progress.step, initial: true);
  }

  @override
  void didUpdateWidget(RoomCarrierMigrationView old) {
    super.didUpdateWidget(old);
    if (old.progress.step != widget.progress.step) {
      _from = old.progress.step;
      _run(widget.progress.step);
    }
    final failed = widget.failure != null;
    if (failed != (old.failure != null)) {
      final reduced = AppMotion.reduced(context);
      if (failed) {
        _stayTimer?.cancel();
        HapticFeedback.heavyImpact();
        reduced ? _fail.value = 1 : _fail.forward();
      } else {
        reduced ? _fail.value = 0 : _fail.reverse();
        _armStay(widget.progress.step);
      }
    }
  }

  void _run(RoomMigrationStep step, {bool initial = false}) {
    _establishedTimer?.cancel();
    final reduced = AppMotion.reduced(context);
    if (reduced) {
      _enter.value = 1;
    } else {
      _enter
        ..duration = _durationOf(step)
        ..forward(from: 0);
    }
    if (!initial) _haptic(step);
    _armStay(step);
    if (step == RoomMigrationStep.established) {
      _establishedTimer = Timer(
        reduced
            ? const Duration(milliseconds: 450)
            : RoomCarrierMigrationView.establishedBeat,
        () {
          if (mounted) widget.onEstablished?.call();
        },
      );
    }
  }

  void _armStay(RoomMigrationStep step) {
    _stayTimer?.cancel();
    if (step == RoomMigrationStep.established) {
      if (_stayOffered) setState(() => _stayOffered = false);
      return;
    }
    if (_stayOffered || widget.onStay == null) return;
    _stayTimer = Timer(widget.stayAfter, () {
      if (mounted) setState(() => _stayOffered = true);
    });
  }

  void _haptic(RoomMigrationStep step) {
    switch (step) {
      case RoomMigrationStep.established:
        HapticFeedback.mediumImpact();
        Future<void>.delayed(
          const Duration(milliseconds: 140),
          HapticFeedback.lightImpact,
        );
      case RoomMigrationStep.moving:
        HapticFeedback.lightImpact();
      default:
        HapticFeedback.selectionClick();
    }
  }

  @override
  void dispose() {
    _establishedTimer?.cancel();
    _stayTimer?.cancel();
    _fail.dispose();
    _enter.dispose();
    _loop.dispose();
    super.dispose();
  }

  ({String title, String detail}) _copy(BuildContext context) {
    final s = context.getString;
    final failure = widget.failure;
    if (failure != null) return (title: failure.title, detail: failure.detail);
    final name = widget.peerName;
    final host = widget.progress.side == RoomMigrationSide.host;
    return switch (widget.progress.step) {
      RoomMigrationStep.found when widget.fellBack => (
        title: s.carriermove_fallback_title,
        detail: s.carriermove_fallback_detail,
      ),
      RoomMigrationStep.found => (
        title: s.carriermove_found_title(name),
        detail: s.carriermove_found_detail,
      ),
      RoomMigrationStep.electing => (
        title: s.carriermove_electing_title,
        detail: s.carriermove_electing_detail,
      ),
      RoomMigrationStep.preparing => (
        title: host
            ? s.carriermove_preparing_host_title
            : s.carriermove_preparing_joiner_title(name),
        detail: s.carriermove_preparing_detail,
      ),
      RoomMigrationStep.moving => (
        title: host
            ? s.carriermove_moving_host_title(name)
            : s.carriermove_moving_joiner_title(name),
        detail: host
            ? s.carriermove_moving_host_detail
            : s.carriermove_moving_joiner_detail,
      ),
      RoomMigrationStep.verifying => (
        title: s.carriermove_verifying_title,
        detail: s.carriermove_verifying_detail,
      ),
      RoomMigrationStep.established => (
        title: s.carriermove_established_title,
        detail: s.carriermove_established_detail,
      ),
    };
  }

  @override
  Widget build(BuildContext context) {
    final rtl = Directionality.of(context) == TextDirection.rtl;
    final reduced = AppMotion.reduced(context);
    final copy = _copy(context);
    final step = widget.progress.step;
    final failed = widget.failure != null;
    final established = step == RoomMigrationStep.established && !failed;
    return LayoutBuilder(
      builder: (context, constraints) {
        final width = math.min(constraints.maxWidth, 420.0);
        return Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(24, 24, 24, 32),
            child: SizedBox(
              width: width - 48,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (widget.caption case final caption?)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 10),
                      child: Text(
                        caption,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          color: AppColors.textSecondary,
                          fontSize: 12,
                          fontWeight: FontWeight.w700,
                          letterSpacing: 1.2,
                        ),
                      ),
                    ),
                  AspectRatio(
                    aspectRatio: _MigrationPainter.canvas.aspectRatio,
                    child: RepaintBoundary(
                      // Drawn left-to-right and mirrored for RTL, so "this
                      // phone" is always on the reading side the person
                      // starts from.
                      child: Transform.flip(
                        flipX: rtl,
                        child: CustomPaint(
                          key: const ValueKey('carrier-migration-scene'),
                          painter: _MigrationPainter(
                            enter: _enter,
                            loop: _loop,
                            fail: _fail,
                            from: _from,
                            step: step,
                            side: widget.progress.side,
                            amber: AppColors.amber,
                            green: AppColors.green,
                            ink: AppColors.textPrimary,
                            muted: AppColors.textSecondary,
                            surface: AppColors.card,
                          ),
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(height: 18),
                  _StepRail(step: step, reduced: reduced, failed: failed),
                  const SizedBox(height: 20),
                  AnimatedSwitcher(
                    duration: reduced ? Duration.zero : AppMotion.entrance,
                    switchInCurve: AppMotion.easeOut,
                    switchOutCurve: AppMotion.leaving,
                    transitionBuilder: (child, animation) => FadeTransition(
                      opacity: animation,
                      child: SlideTransition(
                        position: Tween<Offset>(
                          begin: const Offset(0, .25),
                          end: Offset.zero,
                        ).animate(animation),
                        child: child,
                      ),
                    ),
                    child: Semantics(
                      key: ValueKey('${step.name}|$failed|${copy.title}'),
                      liveRegion: true,
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            copy.title,
                            key: const Key('carrier-migration-title'),
                            textAlign: TextAlign.center,
                            style: TextStyle(
                              color: established
                                  ? AppColors.green
                                  : AppColors.textPrimary,
                              fontSize: 21,
                              fontWeight: FontWeight.w800,
                              height: 1.45,
                            ),
                          ),
                          const SizedBox(height: 8),
                          Text(
                            copy.detail,
                            textAlign: TextAlign.center,
                            style: TextStyle(
                              color: AppColors.textSecondary,
                              fontSize: 13.5,
                              height: 1.7,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                  AnimatedSize(
                    duration: reduced ? Duration.zero : AppMotion.sheet,
                    curve: AppMotion.easeOut,
                    alignment: Alignment.topCenter,
                    child: failed && widget.actions.isNotEmpty
                        ? Padding(
                            key: const ValueKey('carrier-migration-actions'),
                            padding: const EdgeInsets.only(top: 24),
                            child: StaggeredEntrance(
                              builder: (context, children) => Column(
                                crossAxisAlignment: CrossAxisAlignment.stretch,
                                children: [
                                  for (var i = 0; i < children.length; i++) ...[
                                    if (i > 0) const SizedBox(height: 10),
                                    children[i],
                                  ],
                                ],
                              ),
                              children: widget.actions,
                            ),
                          )
                        : const SizedBox(width: double.infinity),
                  ),
                  AnimatedSize(
                    duration: reduced ? Duration.zero : AppMotion.sheet,
                    curve: AppMotion.easeOut,
                    child: AnimatedOpacity(
                      opacity: _stayOffered && !failed ? 1 : 0,
                      duration: reduced ? Duration.zero : AppMotion.entrance,
                      curve: AppMotion.easeOut,
                      child: _stayOffered && !failed
                          ? Padding(
                              padding: const EdgeInsets.only(top: 22),
                              child: TextButton(
                                key: const Key('carrier-migration-stay'),
                                onPressed: widget.onStay,
                                child: Text(context.getString.carriermove_stay),
                              ),
                            )
                          : const SizedBox(width: double.infinity),
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}

/// The six steps as a row of nodes joined by a line that fills as it goes.
/// Done steps tick, the current one breathes, the rest wait in outline.
class _StepRail extends StatelessWidget {
  const _StepRail({
    required this.step,
    required this.reduced,
    this.failed = false,
  });

  final RoomMigrationStep step;
  final bool reduced;

  /// The move stopped at [step]: its node goes quiet instead of breathing.
  final bool failed;

  @override
  Widget build(BuildContext context) {
    final s = context.getString;
    final labels = [
      s.carriermove_step_found,
      s.carriermove_step_electing,
      s.carriermove_step_preparing,
      s.carriermove_step_moving,
      s.carriermove_step_verifying,
      s.carriermove_step_established,
    ];
    final current = step.index;
    final duration = reduced ? Duration.zero : AppMotion.entrance;
    return Semantics(
      label: labels[current],
      value: '${current + 1}/${labels.length}',
      child: ExcludeSemantics(
        child: Row(
          children: [
            for (var i = 0; i < labels.length; i++) ...[
              if (i > 0)
                Expanded(
                  child: Padding(
                    padding: const EdgeInsets.only(bottom: 18),
                    child: Stack(
                      children: [
                        Container(height: 2, color: AppColors.border),
                        AnimatedFractionallySizedBox(
                          duration: duration,
                          curve: AppMotion.easeOut,
                          alignment: AlignmentDirectional.centerStart,
                          widthFactor: i <= current ? 1 : 0,
                          child: AnimatedContainer(
                            duration: duration,
                            height: 2,
                            color: failed
                                ? AppColors.textSecondary
                                : current == labels.length - 1
                                ? AppColors.green
                                : AppColors.amber,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              _RailNode(
                key: ValueKey('carrier-migration-step-$i'),
                label: labels[i],
                state: i < current
                    ? _NodeState.done
                    : i == current
                    ? (failed
                          ? _NodeState.stopped
                          : current == labels.length - 1
                          ? _NodeState.done
                          : _NodeState.current)
                    : _NodeState.waiting,
                finished: current == labels.length - 1,
                duration: duration,
              ),
            ],
          ],
        ),
      ),
    );
  }
}

enum _NodeState { waiting, current, done, stopped }

class _RailNode extends StatelessWidget {
  const _RailNode({
    required this.label,
    required this.state,
    required this.finished,
    required this.duration,
    super.key,
  });

  final String label;
  final _NodeState state;
  final bool finished;
  final Duration duration;

  @override
  Widget build(BuildContext context) {
    final accent = state == _NodeState.stopped
        ? AppColors.textSecondary
        : finished
        ? AppColors.green
        : AppColors.amber;
    final filled = state != _NodeState.waiting;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        AnimatedContainer(
          duration: duration,
          curve: AppMotion.easeOut,
          width: state == _NodeState.current ? 18 : 14,
          height: state == _NodeState.current ? 18 : 14,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: state == _NodeState.done ? accent : Colors.transparent,
            border: Border.all(
              color: filled ? accent : AppColors.border,
              width: 2,
            ),
            boxShadow: state == _NodeState.current
                ? [
                    BoxShadow(
                      color: accent.withValues(alpha: .35),
                      blurRadius: 8,
                    ),
                  ]
                : const [],
          ),
          child: AnimatedSwitcher(
            duration: duration,
            transitionBuilder: (child, animation) =>
                ScaleTransition(scale: animation, child: child),
            child: switch (state) {
              _NodeState.done => Icon(
                Icons.check_rounded,
                key: const ValueKey('done'),
                size: 10,
                color: AppColors.background,
              ),
              // A pause, not a cross: nothing is broken that cannot be
              // picked up again from here.
              _NodeState.stopped => Icon(
                Icons.pause_rounded,
                key: const ValueKey('stopped'),
                size: 10,
                color: accent,
              ),
              _ => const SizedBox.shrink(key: ValueKey('open')),
            },
          ),
        ),
        const SizedBox(height: 4),
        SizedBox(
          height: 14,
          child: Text(
            label,
            maxLines: 1,
            overflow: TextOverflow.visible,
            softWrap: false,
            style: TextStyle(
              fontSize: 9.5,
              fontWeight: state == _NodeState.current
                  ? FontWeight.w800
                  : FontWeight.w600,
              color: filled ? AppColors.textPrimary : AppColors.textSecondary,
            ),
          ),
        ),
      ],
    );
  }
}

/// Router above, this phone bottom-left, the other phone bottom-right.
class _MigrationPainter extends CustomPainter {
  _MigrationPainter({
    required this.enter,
    required this.loop,
    required this.fail,
    required this.from,
    required this.step,
    required this.side,
    required this.amber,
    required this.green,
    required this.ink,
    required this.muted,
    required this.surface,
  }) : super(repaint: Listenable.merge([enter, loop, fail]));

  static const canvas = Size(320, 190);

  final Animation<double> enter;
  final Animation<double> loop;

  /// 0→1 as the move falters: the beam snaps, the signal runs down, colour
  /// drains to grey.
  final Animation<double> fail;
  final RoomMigrationStep from;
  final RoomMigrationStep step;
  final RoomMigrationSide side;
  final Color amber, green, ink, muted, surface;

  static const _router = Offset(160, 34);
  static const _local = Offset(70, 150);
  static const _peer = Offset(250, 150);

  bool get _localHosts => side == RoomMigrationSide.host;
  Offset get _hostAt => _localHosts ? _local : _peer;
  Offset get _joinerAt => _localHosts ? _peer : _local;

  double _ease(double t) => AppMotion.easeOut.transform(t.clamp(0.0, 1.0));

  /// How present the router still is: full while the phones rely on it, dim
  /// once one has let go, gone once the move is proven.
  double _routerPresence(double t) => switch (step) {
    RoomMigrationStep.found ||
    RoomMigrationStep.electing ||
    RoomMigrationStep.preparing => 1,
    RoomMigrationStep.moving => 1 - .55 * _ease(t),
    RoomMigrationStep.verifying => .45,
    RoomMigrationStep.established => .45 * (1 - _ease(t)),
  };

  @override
  void paint(Canvas c, Size size) {
    final sx = size.width / canvas.width;
    final sy = size.height / canvas.height;
    c.save();
    c.scale(sx, sy);
    final t = enter.value;
    final f = _ease(fail.value);
    // A failed move slows to a stop rather than freezing mid-stride.
    final l = loop.value;
    final decided = side != RoomMigrationSide.undecided;
    // The router comes back: it is what the phones still have.
    final routerAlpha = _routerPresence(t) + (1 - _routerPresence(t)) * f;
    final amber = Color.lerp(this.amber, muted, f)!;

    // Router legs. The host keeps its leg until the router fades out (it may
    // still be on the router while hosting); the joiner's lets go when it
    // moves.
    final joinerLegAlpha = switch (step) {
      RoomMigrationStep.moving => 1 - _ease(t),
      RoomMigrationStep.verifying || RoomMigrationStep.established => 0.0,
      _ => 1.0,
    };
    _leg(c, _router, decided ? _hostAt : _local, routerAlpha, l, 0);
    _leg(
      c,
      _router,
      decided ? _joinerAt : _peer,
      routerAlpha * (decided ? joinerLegAlpha : 1),
      l,
      .5,
    );
    _routerIcon(c, routerAlpha);

    // The hotspot's own signal, rising from the host.
    if (decided && step.index >= RoomMigrationStep.preparing.index) {
      final grow = step == RoomMigrationStep.preparing ? _ease(t) : 1.0;
      _radiate(
        c,
        _hostAt,
        grow * (1 - f),
        l,
        done: step == RoomMigrationStep.established && f == 0,
        amber: amber,
      );
    }

    // The direct line between the phones, drawn host → joiner.
    if (decided && step.index >= RoomMigrationStep.moving.index) {
      final drawn = step == RoomMigrationStep.moving ? _ease(t) : 1.0;
      final color = step == RoomMigrationStep.established && f == 0
          ? Color.lerp(amber, green, _ease(t))!
          : amber;
      _beam(c, _hostAt, _joinerAt, drawn, color, snap: f);
      if (step == RoomMigrationStep.verifying && f == 0) {
        // Proofs crossing both ways.
        _packet(c, _hostAt, _joinerAt, l, amber);
        _packet(c, _joinerAt, _hostAt, (l + .5) % 1, amber);
      }
    }

    // Phones. Nudge together on the established beat.
    final pull = step == RoomMigrationStep.established
        ? math.sin(_ease(t) * math.pi) * 6
        : 0.0;
    // On failure the phones ease apart a touch, the way a dropped link
    // feels, then hold.
    final apart = math.sin(f * math.pi / 2) * 5;
    _phone(c, _local + Offset(pull - apart, 0), local: true);
    _phone(c, _peer - Offset(pull - apart, 0), local: false);

    // The crown: sweeping between the phones while electing, settling on the
    // host once decided.
    if (step == RoomMigrationStep.electing && !decided) {
      final swing = (math.sin(l * 2 * math.pi) + 1) / 2;
      _crown(c, Offset.lerp(_local, _peer, swing)!, .55, amber: amber);
    } else if (decided && step.index >= RoomMigrationStep.electing.index) {
      final settle =
          from == RoomMigrationStep.electing ||
              step == RoomMigrationStep.electing
          ? _ease(t)
          : 1.0;
      _crown(c, _hostAt, settle * (1 - .6 * f), amber: amber);
    }

    if (step == RoomMigrationStep.established && f == 0) {
      _burst(c, Offset.lerp(_local, _peer, .5)!, _ease(t));
    }
    if (f > 0) {
      _pauseMark(c, Offset.lerp(_local, _peer, .5)! - const Offset(0, 6), f);
    }
    c.restore();
  }

  void _leg(
    Canvas c,
    Offset a,
    Offset b,
    double alpha,
    double loop,
    double phase,
  ) {
    if (alpha <= 0.01) return;
    final paint = Paint()
      ..color = muted.withValues(alpha: .55 * alpha)
      ..strokeWidth = 2
      ..strokeCap = StrokeCap.round;
    final start = a + const Offset(0, 14);
    final end = b - const Offset(0, 24);
    const dash = 5.0;
    final total = (end - start).distance;
    final dir = (end - start) / total;
    for (var d = 0.0; d < total; d += dash * 2) {
      c.drawLine(
        start + dir * d,
        start + dir * math.min(d + dash, total),
        paint,
      );
    }
    // A packet flowing down the leg.
    final p = (loop + phase) % 1;
    c.drawCircle(
      Offset.lerp(start, end, p)!,
      2.6,
      Paint()..color = amber.withValues(alpha: alpha * .9),
    );
  }

  void _routerIcon(Canvas c, double alpha) {
    if (alpha <= 0.01) return;
    final body = RRect.fromRectAndRadius(
      Rect.fromCenter(center: _router, width: 46, height: 18),
      const Radius.circular(6),
    );
    c.drawRRect(body, Paint()..color = surface.withValues(alpha: alpha));
    c.drawRRect(
      body,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2
        ..color = muted.withValues(alpha: alpha),
    );
    final antenna = Paint()
      ..color = muted.withValues(alpha: alpha)
      ..strokeWidth = 2
      ..strokeCap = StrokeCap.round;
    c.drawLine(
      _router + const Offset(-14, -9),
      _router + const Offset(-18, -22),
      antenna,
    );
    c.drawLine(
      _router + const Offset(14, -9),
      _router + const Offset(18, -22),
      antenna,
    );
    for (var i = 0; i < 3; i++) {
      c.drawCircle(
        _router + Offset(-10 + i * 10, 0),
        2,
        Paint()..color = amber.withValues(alpha: alpha * .8),
      );
    }
  }

  void _radiate(
    Canvas c,
    Offset at,
    double grow,
    double loop, {
    required bool done,
    required Color amber,
  }) {
    if (grow <= 0.01) return;
    final color = done ? green : amber;
    for (var i = 0; i < 3; i++) {
      final phase = (loop + i / 3) % 1;
      final radius = (26 + phase * 34) * grow;
      final alpha = (1 - phase) * .45 * grow;
      c.drawArc(
        Rect.fromCircle(center: at - const Offset(0, 22), radius: radius),
        -math.pi * .85,
        math.pi * .7,
        false,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2
          ..strokeCap = StrokeCap.round
          ..color = color.withValues(alpha: alpha),
      );
    }
  }

  void _beam(
    Canvas c,
    Offset a,
    Offset b,
    double drawn,
    Color color, {
    double snap = 0,
  }) {
    if (drawn <= 0) return;
    final y = a.dy - 6;
    final from = Offset(a.dx + (b.dx > a.dx ? 18 : -18), y);
    final to = Offset(b.dx + (b.dx > a.dx ? -18 : 18), y);
    final end = Offset.lerp(from, to, drawn)!;
    void stroke(Offset p, Offset q) {
      c.drawLine(
        p,
        q,
        Paint()
          ..color = color.withValues(alpha: .22 * (1 - snap))
          ..strokeWidth = 10
          ..strokeCap = StrokeCap.round,
      );
      c.drawLine(
        p,
        q,
        Paint()
          ..color = color.withValues(alpha: 1 - .4 * snap)
          ..strokeWidth = 3
          ..strokeCap = StrokeCap.round,
      );
    }

    if (snap <= 0) {
      stroke(from, end);
      return;
    }
    // Snapping: the two halves pull back from the middle and droop.
    final mid = Offset.lerp(from, end, .5)!;
    final gap = 22 * snap;
    final droop = Offset(0, 9 * snap);
    final dir = (end - from) / (end - from).distance;
    stroke(from, mid - dir * gap + droop);
    stroke(mid + dir * gap + droop, end);
  }

  /// Two calm bars where the phones met: stopped, not broken.
  void _pauseMark(Canvas c, Offset at, double t) {
    final paint = Paint()
      ..color = muted.withValues(alpha: t)
      ..strokeWidth = 3.4
      ..strokeCap = StrokeCap.round;
    final h = 7 * t;
    c.drawLine(at + Offset(-4, -h), at + Offset(-4, h), paint);
    c.drawLine(at + Offset(4, -h), at + Offset(4, h), paint);
  }

  void _packet(Canvas c, Offset a, Offset b, double t, Color color) {
    final y = a.dy - 6;
    final from = Offset(a.dx + (b.dx > a.dx ? 18 : -18), y);
    final to = Offset(b.dx + (b.dx > a.dx ? -18 : 18), y);
    c.drawCircle(Offset.lerp(from, to, t)!, 4, Paint()..color = color);
  }

  void _phone(Canvas c, Offset at, {required bool local}) {
    final body = RRect.fromRectAndRadius(
      Rect.fromCenter(center: at, width: 30, height: 48),
      const Radius.circular(7),
    );
    c.drawRRect(body, Paint()..color = surface);
    c.drawRRect(
      body,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2.2
        ..color = local ? ink : muted,
    );
    c.drawLine(
      at + const Offset(-5, 18),
      at + const Offset(5, 18),
      Paint()
        ..color = local ? ink : muted
        ..strokeWidth = 2
        ..strokeCap = StrokeCap.round,
    );
  }

  void _crown(Canvas c, Offset phone, double t, {required Color amber}) {
    if (t <= 0) return;
    final at = phone - Offset(0, 36 + 6 * (1 - t));
    final path = Path()
      ..moveTo(at.dx - 9, at.dy + 4)
      ..lineTo(at.dx - 9, at.dy - 4)
      ..lineTo(at.dx - 4, at.dy)
      ..lineTo(at.dx, at.dy - 7)
      ..lineTo(at.dx + 4, at.dy)
      ..lineTo(at.dx + 9, at.dy - 4)
      ..lineTo(at.dx + 9, at.dy + 4)
      ..close();
    c.drawPath(path, Paint()..color = amber.withValues(alpha: t));
  }

  void _burst(Canvas c, Offset at, double t) {
    if (t <= 0 || t >= 1) return;
    final radius = 10 + 50 * t;
    c.drawCircle(
      at - const Offset(0, 6),
      radius,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 3 * (1 - t)
        ..color = green.withValues(alpha: (1 - t) * .8),
    );
  }

  @override
  bool shouldRepaint(_MigrationPainter old) =>
      old.step != step ||
      old.side != side ||
      old.from != from ||
      old.amber != amber ||
      old.green != green ||
      old.ink != ink;
}
