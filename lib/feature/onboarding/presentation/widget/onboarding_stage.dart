import 'dart:math' as math;
import 'dart:ui' show lerpDouble;

import 'package:flutter/material.dart';

import '../../../../core/motion/app_motion.dart';
import '../../../../core/theme/app_colors.dart';
import '../../../../core/widget/app_avatar.dart';
import '../../../../core/widget/tark_mark.dart';
import '../../../room/api/room_api.dart';

/// The one object that never leaves the screen during onboarding: the
/// **beacon**.
///
/// It is a single continuous figure driven by [pose], a spring-driven value
/// that runs 0 → 1 → 2 across the three movements, so every change of step is
/// the same object moving rather than one picture being swapped for another:
///
/// * **0 — hello.** The Tarkk mark sits between two phones on a signal line
///   (the website's "phone to phone" motif), light travelling along it in
///   both directions into the mark.
/// * **1 — you.** The two phones slide into the beacon and become one — you.
///   The mark gives way to your face and the beacon swells to hold it.
/// * **2 — your room.** Your face collapses into a single point and a Room
///   blooms out of it — the same [RoomFormation] the creation screen draws,
///   with you already sitting in its first seat and two seats waiting for
///   your crew. It flies on to the creation screen as a [Hero].
///
/// [ambient] is a slow 0..1 loop for the travelling light and the orbiting
/// arc; [scale] shrinks the whole figure on short screens (and with the
/// keyboard up). Everything here is a CustomPainter plus two small widgets,
/// isolated behind a RepaintBoundary — cheap enough to run every frame on the
/// floor device.
class OnboardingStage extends StatelessWidget {
  const OnboardingStage({
    required this.pose,
    required this.ambient,
    required this.avatarId,
    required this.scale,
    this.intro = kAlwaysCompleteAnimation,
    this.formationWidth,
    super.key,
  });

  final Animation<double> pose;
  final Animation<double> ambient;
  final int? avatarId;
  final double scale;

  /// The figure assembling itself on first sight, 0 → 1: the beacon springs
  /// up, its dial sweeps round, the two phones slide in from the edges and
  /// the signal line draws itself from each phone into the beacon before the
  /// first light travels along it. Complete (the default) shows it whole.
  final Animation<double> intro;

  /// [t] mapped onto the window [begin]..[end] of the intro, eased out.
  static double _phase(double t, double begin, double end) => AppMotion.easeOut
      .transform(((t - begin) / (end - begin)).clamp(0.0, 1.0));

  /// Width of the room formation's box — the same width the creation
  /// screen gives its own, so the [Hero] flight only has to move, not
  /// stretch. Defaults to the stage's width.
  final double? formationWidth;

  /// The formation's own box height (see [RoomFormation]).
  static const double formationHeight = 200;

  /// Where the formation's first member sits, relative to its centre.
  static const double _seatLift = 28;

  static double _room(double p) {
    final e = (p - 1).clamp(0.0, 1.0);
    // A hair of spring overshoot past "you" must not flash the room in.
    return e < 0.04 ? 0 : e;
  }

  /// The beacon's diameter for [p] at unit scale.
  static double _diameter(double p) {
    if (p <= 1) return lerpDouble(96, 132, p.clamp(0.0, 1.0))!;
    return lerpDouble(132, 26, Curves.easeIn.transform(_room(p)))!;
  }

  static Offset _beaconCenter(Size size, double p, double scale) {
    final c = size.center(Offset.zero);
    final lift = _seatLift * scale * Curves.easeOut.transform(_room(p));
    return c.translate(0, -lift);
  }

  @override
  Widget build(BuildContext context) {
    return RepaintBoundary(
      child: LayoutBuilder(
        builder: (context, constraints) {
          final size = constraints.biggest;
          final formationBox = Size(
            formationWidth ?? size.width,
            formationHeight,
          );
          return Stack(
            clipBehavior: Clip.none,
            children: [
              Positioned.fill(
                child: CustomPaint(
                  painter: _StagePainter(
                    pose: pose,
                    ambient: ambient,
                    intro: intro,
                    scale: scale,
                    accent: AppColors.amber,
                    line: AppColors.border,
                    card: AppColors.card,
                    glyph: AppColors.textSecondary,
                    // Directional: the light travels the way the language
                    // reads, so it always arrives *into* the beacon.
                    rtl: Directionality.of(context) == TextDirection.rtl,
                  ),
                ),
              ),
              _Formation(
                pose: pose,
                stage: size,
                box: formationBox,
                scale: scale,
                avatarId: avatarId,
              ),
              _Beacon(
                pose: pose,
                intro: intro,
                stage: size,
                scale: scale,
                avatarId: avatarId,
              ),
            ],
          );
        },
      ),
    );
  }
}

/// The disc itself: the Tarkk mark, then your face.
class _Beacon extends StatelessWidget {
  const _Beacon({
    required this.pose,
    required this.intro,
    required this.stage,
    required this.scale,
    required this.avatarId,
  });

  final Animation<double> pose;
  final Animation<double> intro;
  final Size stage;
  final double scale;
  final int? avatarId;

  @override
  Widget build(BuildContext context) {
    final mark = TarkMark(
      size: 44,
      color: AppColors.amber,
      colorDim: AppColors.amberDim,
    );
    final face = _Face(avatarId: avatarId);
    return AnimatedBuilder(
      animation: Listenable.merge([pose, intro]),
      builder: (context, _) {
        final p = pose.value;
        // Springs up out of nothing on first sight, with a little give.
        final arrive = Curves.easeOutBack.transform(
          (intro.value / 0.55).clamp(0.0, 1.0),
        );
        final d = OnboardingStage._diameter(p) * scale * (0.35 + 0.65 * arrive);
        final c = OnboardingStage._beaconCenter(stage, p, scale);
        final room = OnboardingStage._room(p);
        // The beacon hands over to the face sitting in the formation's first
        // seat at the very end, where the two are the same size and place.
        final present =
            (1 - ((room - 0.82) / 0.18).clamp(0.0, 1.0)) *
            OnboardingStage._phase(intro.value, 0, 0.3);
        if (present <= 0) return const SizedBox.shrink();
        final faceShown = Curves.easeInOut.transform(
          ((p - 0.25) / 0.5).clamp(0.0, 1.0),
        );
        final ring = (1.5 + 1 * (1 - room)).clamp(1.5, 2.5);
        return Positioned(
          left: c.dx - d / 2,
          top: c.dy - d / 2,
          width: d,
          height: d,
          child: IgnorePointer(
            child: Opacity(
              opacity: present,
              child: DecoratedBox(
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: AppColors.card,
                  border: Border.all(
                    color: AppColors.amber.withValues(
                      alpha: 0.55 + 0.35 * faceShown,
                    ),
                    width: ring,
                  ),
                  boxShadow: [
                    BoxShadow(
                      color: AppColors.amber.withValues(
                        alpha: 0.22 * (1 - room),
                      ),
                      blurRadius: 26,
                    ),
                  ],
                ),
                child: Padding(
                  padding: EdgeInsets.all(ring),
                  child: Stack(
                    fit: StackFit.expand,
                    children: [
                      if (faceShown < 1)
                        Opacity(
                          key: const ValueKey('mark'),
                          opacity: 1 - faceShown,
                          child: FittedBox(
                            child: Padding(
                              padding: const EdgeInsets.all(22),
                              child: mark,
                            ),
                          ),
                        ),
                      if (faceShown > 0)
                        Opacity(
                          key: const ValueKey('face'),
                          opacity: faceShown,
                          child: face,
                        ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

/// The face, with a little spring when a new one is picked: the old face
/// shrinks away under the new one as it pops in.
class _Face extends StatelessWidget {
  const _Face({required this.avatarId});

  final int? avatarId;

  @override
  Widget build(BuildContext context) {
    final reduced = AppMotion.reduced(context);
    return LayoutBuilder(
      builder: (context, constraints) => AnimatedSwitcher(
        duration: reduced ? AppMotion.card : const Duration(milliseconds: 520),
        switchInCurve: reduced ? AppMotion.easeOut : Curves.easeOutBack,
        switchOutCurve: AppMotion.leaving,
        transitionBuilder: (child, animation) {
          final fade = FadeTransition(opacity: animation, child: child);
          if (reduced) return fade;
          return ScaleTransition(
            scale: Tween<double>(begin: 0.6, end: 1).animate(animation),
            child: fade,
          );
        },
        child: KeyedSubtree(
          key: ValueKey(avatarId),
          child: avatarId != null && AvatarPicture.shows(avatarId)
              ? AvatarPicture(
                  avatarId: avatarId!,
                  size: constraints.biggest.shortestSide,
                )
              : const SizedBox.expand(),
        ),
      ),
    );
  }
}

/// The Room blooming out of the beacon, under the [Hero] tag the creation
/// screen's formation uses.
class _Formation extends StatelessWidget {
  const _Formation({
    required this.pose,
    required this.stage,
    required this.box,
    required this.scale,
    required this.avatarId,
  });

  final Animation<double> pose;
  final Size stage;
  final Size box;
  final double scale;
  final int? avatarId;

  /// Crossfades the two formations during the flight, so your face in the
  /// first seat dissolves into the creation screen's blank formation rather
  /// than blinking out at take-off.
  static Widget _shuttle(
    BuildContext flightContext,
    Animation<double> animation,
    HeroFlightDirection direction,
    BuildContext fromHeroContext,
    BuildContext toHeroContext,
  ) {
    final from = (fromHeroContext.widget as Hero).child;
    final to = (toHeroContext.widget as Hero).child;
    final toward = direction == HeroFlightDirection.push
        ? animation
        : ReverseAnimation(animation);
    return Stack(
      fit: StackFit.expand,
      children: [
        FadeTransition(opacity: ReverseAnimation(toward), child: from),
        FadeTransition(opacity: toward, child: to),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final seat = 26.0;
    final hero = Hero(
      tag: roomFormationHeroTag,
      flightShuttleBuilder: _shuttle,
      child: SizedBox.fromSize(
        size: box,
        child: Stack(
          fit: StackFit.expand,
          children: [
            const RoomFormation(),
            // You, already in the first seat.
            Align(
              alignment: Alignment(
                0,
                -OnboardingStage._seatLift / (box.height / 2),
              ),
              child: _SeatFace(avatarId: avatarId, size: seat, pose: pose),
            ),
          ],
        ),
      ),
    );
    return AnimatedBuilder(
      animation: pose,
      child: hero,
      builder: (context, child) {
        final room = OnboardingStage._room(pose.value);
        if (room <= 0) return const SizedBox.shrink();
        final c = stage.center(Offset.zero);
        final bloom = Curves.easeOut.transform(room);
        return Positioned(
          left: c.dx - box.width / 2,
          top: c.dy - box.height / 2,
          width: box.width,
          height: box.height,
          child: Transform.scale(
            scale: scale * (0.55 + 0.45 * bloom),
            child: Opacity(
              opacity: ((room - 0.05) / 0.6).clamp(0.0, 1.0),
              child: child,
            ),
          ),
        );
      },
    );
  }
}

class _SeatFace extends StatelessWidget {
  const _SeatFace({
    required this.avatarId,
    required this.size,
    required this.pose,
  });

  final int? avatarId;
  final double size;
  final Animation<double> pose;

  @override
  Widget build(BuildContext context) {
    final face = Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: AppColors.card,
        border: Border.all(color: AppColors.amber, width: 1.5),
      ),
      child: avatarId != null && AvatarPicture.shows(avatarId)
          ? AvatarPicture(avatarId: avatarId!, size: size - 3)
          : null,
    );
    return AnimatedBuilder(
      animation: pose,
      child: face,
      builder: (context, child) => Opacity(
        opacity: ((OnboardingStage._room(pose.value) - 0.82) / 0.18).clamp(
          0.0,
          1.0,
        ),
        child: child,
      ),
    );
  }
}

/// The signal line, the two phones on it, the light travelling into the
/// beacon, and the orbit around it.
class _StagePainter extends CustomPainter {
  _StagePainter({
    required this.pose,
    required this.ambient,
    required this.intro,
    required this.scale,
    required this.accent,
    required this.line,
    required this.card,
    required this.glyph,
    required this.rtl,
  }) : super(repaint: Listenable.merge([pose, ambient, intro]));

  final Animation<double> pose;
  final Animation<double> ambient;
  final Animation<double> intro;
  final double scale;
  final Color accent;
  final Color line;
  final Color card;
  final Color glyph;
  final bool rtl;

  late final TextPainter _phone = TextPainter(
    textDirection: TextDirection.ltr,
    text: TextSpan(
      text: String.fromCharCode(Icons.smartphone_rounded.codePoint),
      style: TextStyle(
        fontFamily: Icons.smartphone_rounded.fontFamily,
        package: Icons.smartphone_rounded.fontPackage,
        fontSize: 17 * scale,
        color: glyph,
      ),
    ),
  )..layout();

  @override
  void paint(Canvas canvas, Size size) {
    final p = pose.value;
    final a = ambient.value;
    final i = intro.value;
    final ringIn = OnboardingStage._phase(i, 0.1, 0.8);
    final phonesIn = OnboardingStage._phase(i, 0.15, 0.6);
    final lineIn = OnboardingStage._phase(i, 0.35, 0.85);
    final lightIn = OnboardingStage._phase(i, 0.7, 1);
    final room = OnboardingStage._room(p);
    final hello = (1 - p).clamp(0.0, 1.0);
    final c = OnboardingStage._beaconCenter(size, p, scale);
    final r = OnboardingStage._diameter(p) * scale / 2;

    // Orbit: a thin ring just outside the beacon with one bright arc riding
    // it, and a dial of ticks — the radar the Landing logo also wears.
    final orbit = (1 - room * 1.8).clamp(0.0, 1.0) * ringIn;
    if (orbit > 0) {
      final ringR = r + 12 * scale;
      final pen = Paint()
        ..style = PaintingStyle.stroke
        ..strokeCap = StrokeCap.round;
      canvas.drawCircle(
        c,
        r * 1.9,
        Paint()
          ..shader = RadialGradient(
            colors: [
              accent.withValues(alpha: 0.14 * orbit),
              accent.withValues(alpha: 0),
            ],
          ).createShader(Rect.fromCircle(center: c, radius: r * 1.9)),
      );
      pen
        ..strokeWidth = 1
        ..color = line.withValues(alpha: orbit);
      // The dial sweeps round on first sight, then simply sits there.
      canvas.drawArc(
        Rect.fromCircle(center: c, radius: ringR),
        -math.pi / 2,
        2 * math.pi * ringIn,
        false,
        pen,
      );
      pen
        ..strokeWidth = 2.2
        ..color = accent.withValues(alpha: 0.85 * orbit);
      final start = a * 2 * math.pi - math.pi / 2;
      canvas.drawArc(
        Rect.fromCircle(center: c, radius: ringR),
        start,
        0.9,
        false,
        pen,
      );
      pen
        ..strokeWidth = 1
        ..color = line.withValues(alpha: 0.9 * orbit);
      final tickR = ringR + 7 * scale;
      final ticks = (48 * ringIn).round();
      for (var t = 0; t < ticks; t++) {
        final angle = t * math.pi / 24 - math.pi / 2;
        final long = t % 4 == 0;
        final dir = Offset(math.cos(angle), math.sin(angle));
        canvas.drawLine(
          c + dir * tickR,
          c + dir * (tickR + (long ? 5 : 2.5) * scale),
          pen,
        );
      }
    }

    if (hello <= 0) return;

    // The two phones close in on the beacon as "hello" becomes "you".
    final reach = math.min(size.width * 0.4, 168 * scale);
    final travel =
        lerpDouble(r + 22 * scale, reach, hello)! + (1 - phonesIn) * 70 * scale;
    final er = 19 * scale;
    final shown = hello * phonesIn;
    final linePaint = Paint()
      ..strokeWidth = 1.2
      ..color = line.withValues(alpha: hello);
    for (final side in const [-1.0, 1.0]) {
      final end = c.translate(side * travel, 0);
      final edge = c.translate(side * (r + 12 * scale), 0);
      final from = end.translate(-side * er, 0);
      if ((from.dx - edge.dx) * side > 0 && lineIn > 0) {
        // Drawn from the phone toward the beacon as it first appears.
        canvas.drawLine(from, Offset.lerp(from, edge, lineIn)!, linePaint);
        // Light leaving each phone for the beacon, two packets per side,
        // offset so the pair never arrive together. In RTL the phrase reads
        // the other way, so the leading packet does too.
        for (var k = 0; k < 2; k++) {
          final phase =
              (a * 4 + k * 0.5 + (side * (rtl ? -1 : 1) > 0 ? 0.25 : 0)) % 1;
          final eased = Curves.easeIn.transform(phase);
          final dot = Offset.lerp(from, edge, eased)!;
          final glow = math.sin(math.pi * phase) * hello * lightIn;
          canvas.drawCircle(
            dot,
            5 * scale,
            Paint()..color = accent.withValues(alpha: 0.16 * glow),
          );
          canvas.drawCircle(
            dot,
            2.2 * scale,
            Paint()..color = accent.withValues(alpha: 0.95 * glow),
          );
        }
      }
      // The phone.
      canvas.drawCircle(
        end,
        er,
        Paint()..color = card.withValues(alpha: shown),
      );
      canvas.drawCircle(
        end,
        er,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.2
          ..color = line.withValues(alpha: shown),
      );
      // A layer only while the phones are fading — at rest the glyph is
      // painted straight onto the canvas.
      final fading = shown < 0.999;
      if (fading) {
        canvas.saveLayer(
          Rect.fromCircle(center: end, radius: er),
          Paint()..color = Color.fromRGBO(0, 0, 0, shown),
        );
      }
      _phone.paint(canvas, end - Offset(_phone.width / 2, _phone.height / 2));
      if (fading) canvas.restore();
    }
  }

  @override
  bool shouldRepaint(_StagePainter old) =>
      old.pose != pose ||
      old.ambient != ambient ||
      old.intro != intro ||
      old.scale != scale ||
      old.accent != accent ||
      old.line != line ||
      old.card != card ||
      old.glyph != glyph ||
      old.rtl != rtl;
}
