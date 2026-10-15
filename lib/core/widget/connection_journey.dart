import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../motion/app_motion.dart';
import '../theme/app_colors.dart';

/// Which kind of link a [ConnectionJourney] is drawing. Each one moves
/// differently on purpose: the motion is the explanation of what the phones
/// are actually doing, so a hotspot, a Bluetooth pairing and a shared router
/// must not all look like the same spinner.
enum JourneyLink {
  /// The other phone is the access point: it radiates, this phone is pulled
  /// in along the beam.
  hotspot,

  /// A point-to-point radio tether: a living wave between the two phones,
  /// with each phone's radio circling it.
  bluetooth,

  /// Both phones hang off a router above them, traffic flowing down both
  /// legs.
  sharedWifi,
}

/// Where the connection is. A [ConnectionJourney] morphs between these
/// rather than swapping screens: the scanned code collapses into the node the
/// link grows from, the link either locks green or snaps, and that same scene
/// is what the channel opens out of.
enum JourneyStage {
  /// The code was read. The camera is gone; the brackets that framed the code
  /// fold into a ring and tick.
  scanned,

  /// The phones are finding each other over [JourneyLink].
  linking,

  /// Both ends proved themselves. The link locks and the phones snap together.
  established,

  /// It did not happen. The link snaps and the way forward is offered.
  failed,
}

/// The one scene every "connecting two phones" moment in the app is told in.
///
/// Replaces a camera that kept running after its job was done, a spinner, and
/// a separate success page with a single continuous stage. Driven entirely by
/// [stage]: the owner changes it and the scene choreographs its own way there.
class ConnectionJourney extends StatefulWidget {
  const ConnectionJourney({
    required this.stage,
    required this.link,
    required this.title,
    this.detail,
    this.caption,
    this.actions = const [],
    this.onEstablished,
    this.continued = false,
    super.key,
  });

  final JourneyStage stage;
  final JourneyLink link;

  /// One short line saying what is happening, in the user's words.
  final String title;

  /// A second, quieter line: the hint or the reason.
  final String? detail;

  /// Small caps over the scene, e.g. the Room's name.
  final String? caption;

  /// Recovery or follow-up controls, shown under the text. Entrances are
  /// staggered; the first is meant to be the primary.
  final List<Widget> actions;

  /// Called once the established beat has landed, so the owner can open the
  /// channel out of it rather than over it.
  final VoidCallback? onEstablished;

  /// The scene is picking up where another screen left it (the scan page
  /// hands over to the channel's entry mid-link), so the first stage starts
  /// already in place instead of entering again.
  final bool continued;

  /// How long the established beat holds before [onEstablished] fires.
  static const establishedBeat = Duration(milliseconds: 1150);

  @override
  State<ConnectionJourney> createState() => _ConnectionJourneyState();
}

class _ConnectionJourneyState extends State<ConnectionJourney>
    with TickerProviderStateMixin {
  /// 0→1 each time the stage changes: the transition into that stage.
  late final AnimationController _enter = AnimationController(vsync: this);

  /// Ambient flow while linking: packets, waves, orbits.
  late final AnimationController _loop = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 2400),
  );

  late JourneyStage _from = widget.stage;

  /// The stage the scene is actually showing. It trails [widget.stage] only
  /// while the scanned beat is still playing: a link that comes up (or fails)
  /// a few frames after the read must not cut the tick off half drawn.
  late JourneyStage _shown = widget.stage;
  Timer? _establishedTimer;
  bool _started = false;

  static Duration _durationOf(JourneyStage stage) => switch (stage) {
    JourneyStage.scanned => const Duration(milliseconds: 760),
    JourneyStage.linking => const Duration(milliseconds: 620),
    JourneyStage.established => const Duration(milliseconds: 980),
    JourneyStage.failed => const Duration(milliseconds: 1000),
  };

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_started) return;
    _started = true;
    _loop.loopUnlessReduced(context);
    _run(widget.stage, initial: true);
  }

  @override
  void didUpdateWidget(ConnectionJourney old) {
    super.didUpdateWidget(old);
    if (old.stage != widget.stage) _advance();
  }

  void _advance() {
    if (!mounted || widget.stage == _shown) return;
    if (_shown == JourneyStage.scanned && _enter.isAnimating) {
      _enter.forward().whenCompleteOrCancel(_advance);
      return;
    }
    setState(() {
      _from = _shown;
      _shown = widget.stage;
    });
    _run(_shown);
  }

  void _run(JourneyStage stage, {bool initial = false}) {
    _establishedTimer?.cancel();
    final reduced = AppMotion.reduced(context);
    if (!(initial && widget.continued)) _haptic(stage, initial: initial);
    if (reduced || (initial && widget.continued)) {
      _enter.value = 1;
    } else {
      _enter
        ..duration = _durationOf(stage)
        ..forward(from: 0);
    }
    if (stage == JourneyStage.established) {
      _establishedTimer = Timer(
        reduced
            ? const Duration(milliseconds: 450)
            : ConnectionJourney.establishedBeat,
        () {
          if (mounted) widget.onEstablished?.call();
        },
      );
    }
  }

  void _haptic(JourneyStage stage, {required bool initial}) {
    switch (stage) {
      case JourneyStage.scanned:
        HapticFeedback.mediumImpact();
      case JourneyStage.linking:
        if (!initial) HapticFeedback.selectionClick();
      case JourneyStage.established:
        HapticFeedback.mediumImpact();
        Future<void>.delayed(
          const Duration(milliseconds: 140),
          HapticFeedback.lightImpact,
        );
      case JourneyStage.failed:
        HapticFeedback.heavyImpact();
    }
  }

  @override
  void dispose() {
    _establishedTimer?.cancel();
    _enter.dispose();
    _loop.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final rtl = Directionality.of(context) == TextDirection.rtl;
    final reduced = AppMotion.reduced(context);
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
                    aspectRatio: _JourneyPainter.canvas.aspectRatio,
                    child: RepaintBoundary(
                      child: Transform.flip(
                        flipX: rtl,
                        child: CustomPaint(
                          key: ValueKey(
                            'connection-journey-${widget.link.name}',
                          ),
                          painter: _JourneyPainter(
                            enter: _enter,
                            loop: _loop,
                            from: _from,
                            stage: _shown,
                            link: widget.link,
                            amber: AppColors.amber,
                            green: AppColors.green,
                            red: AppColors.red,
                            ink: AppColors.textPrimary,
                            surface: AppColors.card,
                            mirrored: rtl,
                          ),
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(height: 22),
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
                      key: ValueKey('${widget.stage.name}|${widget.title}'),
                      liveRegion: true,
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            widget.title,
                            key: const Key('connection-journey-title'),
                            textAlign: TextAlign.center,
                            style: TextStyle(
                              color: switch (widget.stage) {
                                JourneyStage.established => AppColors.green,
                                JourneyStage.failed => AppColors.textPrimary,
                                _ => AppColors.textPrimary,
                              },
                              fontSize: 21,
                              fontWeight: FontWeight.w800,
                              height: 1.45,
                            ),
                          ),
                          if (widget.detail case final detail?) ...[
                            const SizedBox(height: 8),
                            Text(
                              detail,
                              textAlign: TextAlign.center,
                              style: TextStyle(
                                color: AppColors.textSecondary,
                                fontSize: 13.5,
                                height: 1.7,
                              ),
                            ),
                          ],
                        ],
                      ),
                    ),
                  ),
                  if (widget.actions.isNotEmpty) ...[
                    const SizedBox(height: 26),
                    _StaggeredActions(
                      key: ValueKey('actions-${widget.stage.name}'),
                      reduced: reduced,
                      children: widget.actions,
                    ),
                  ],
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}

/// Recovery controls rising in one after another, the primary first.
class _StaggeredActions extends StatefulWidget {
  const _StaggeredActions({
    required this.children,
    required this.reduced,
    super.key,
  });

  final List<Widget> children;
  final bool reduced;

  @override
  State<_StaggeredActions> createState() => _StaggeredActionsState();
}

class _StaggeredActionsState extends State<_StaggeredActions>
    with SingleTickerProviderStateMixin {
  late final AnimationController _rise = AnimationController(
    vsync: this,
    duration: Duration(milliseconds: 420 + 70 * widget.children.length),
  );

  @override
  void initState() {
    super.initState();
    if (widget.reduced) {
      _rise.value = 1;
    } else {
      // Let the snap of the link land first: the way forward follows it.
      Future<void>.delayed(const Duration(milliseconds: 380), () {
        if (mounted) _rise.forward();
      });
    }
  }

  @override
  void dispose() {
    _rise.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final count = widget.children.length;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (var i = 0; i < count; i++)
          Padding(
            padding: EdgeInsets.only(top: i == 0 ? 0 : 10),
            child: AnimatedBuilder(
              animation: _rise,
              builder: (context, child) {
                final start = i * .14;
                final t = Curves.easeOutBack.transform(
                  ((_rise.value - start) / (1 - start)).clamp(0.0, 1.0),
                );
                return Opacity(
                  opacity: t.clamp(0.0, 1.0),
                  child: Transform.translate(
                    offset: Offset(0, 18 * (1 - t)),
                    child: child,
                  ),
                );
              },
              child: widget.children[i],
            ),
          ),
      ],
    );
  }
}

double _span(double v, double a, double b) =>
    ((v - a) / (b - a)).clamp(0.0, 1.0);

/// Draws the whole stage in one painter: two phones, the link between them
/// in the shape of [link], and the transition from [from] into [stage].
///
/// Everything is drawn in a fixed 300×210 space and scaled, so the
/// choreography is the same on every screen. Per frame it is a handful of
/// paths and circles — no blurs, no saveLayer, no clipping — which is what
/// the S8+ floor allows.
class _JourneyPainter extends CustomPainter {
  _JourneyPainter({
    required this.enter,
    required this.loop,
    required this.from,
    required this.stage,
    required this.link,
    required this.amber,
    required this.green,
    required this.red,
    required this.ink,
    required this.surface,
    required this.mirrored,
  }) : super(repaint: Listenable.merge([enter, loop]));

  final Animation<double> enter;
  final Animation<double> loop;
  final JourneyStage from;
  final JourneyStage stage;
  final JourneyLink link;
  final Color amber, green, red, ink, surface;

  /// The scene is flipped for right-to-left so "me" stays on the reading
  /// start; a tick is a glyph, though, and must not read backwards.
  final bool mirrored;

  static const canvas = Size(300, 210);
  static const _me = Offset(62, 132);
  static const _peer = Offset(238, 132);
  static const _hub = Offset(150, 132);
  static const _routerAt = Offset(150, 34);

  Color get _bluetooth => const Color(0xFF5FA8FF);

  Color get _linkColor => switch (link) {
    JourneyLink.bluetooth => _bluetooth,
    _ => amber,
  };

  Paint _stroke(Color color, [double width = 2]) => Paint()
    ..color = color
    ..style = PaintingStyle.stroke
    ..strokeWidth = width
    ..strokeCap = StrokeCap.round
    ..strokeJoin = StrokeJoin.round;

  Paint _fill(Color color) => Paint()..color = color;

  @override
  void paint(Canvas c, Size size) {
    c.save();
    c.scale(size.width / canvas.width, size.height / canvas.height);
    final t = enter.value;
    switch (stage) {
      case JourneyStage.scanned:
        _paintScanned(c, t);
      case JourneyStage.linking:
        _paintLinking(c, t);
      case JourneyStage.established:
        _paintEstablished(c, t);
      case JourneyStage.failed:
        _paintFailed(c, t);
    }
    c.restore();
  }

  // ------------------------------------------------------------- scanned

  void _paintScanned(Canvas c, double t) {
    final fold = AppMotion.easeOut.transform(_span(t, 0, .55));
    final color = Color.lerp(amber, green, _span(t, .25, .6))!;
    // The scanner's brackets, folding in on the code they just read.
    final half = 62 - 38 * fold;
    final arm = 22 - 10 * fold;
    final bracketAlpha = 1 - _span(t, .45, .7);
    if (bracketAlpha > 0) {
      final p = _stroke(color.withValues(alpha: bracketAlpha), 3.4);
      for (final sx in const [-1.0, 1.0]) {
        for (final sy in const [-1.0, 1.0]) {
          final corner = _hub.translate(sx * half, sy * half - 22);
          final path = Path()
            ..moveTo(corner.dx, corner.dy - sy * arm)
            ..lineTo(corner.dx, corner.dy)
            ..lineTo(corner.dx - sx * arm, corner.dy);
          c.drawPath(path, p);
        }
      }
    }
    // …into a ring that ticks.
    final ring = _span(t, .42, .72);
    final center = _hub.translate(0, -22);
    if (ring > 0) {
      final r = 26 * Curves.easeOutBack.transform(ring);
      c.drawCircle(center, r, _fill(green.withValues(alpha: .14 * ring)));
      c.drawCircle(center, r, _stroke(green.withValues(alpha: ring), 2.2));
      _tick(c, center, _span(t, .55, .85), green, 9);
    }
    // A burst of sparks, the code's pixels scattering.
    final burst = _span(t, .45, 1);
    if (burst > 0 && burst < 1) {
      for (var i = 0; i < 12; i++) {
        final a = i * math.pi / 6 + .26;
        final d = 30 + 46 * AppMotion.easeOut.transform(burst);
        final pos = center + Offset(math.cos(a), math.sin(a)) * d;
        c.drawCircle(
          pos,
          2.2 * (1 - burst) + .6,
          _fill((i.isEven ? green : amber).withValues(alpha: 1 - burst)),
        );
      }
    }
    // The phones arrive out of the ring: this is who is about to connect.
    final arrive = Curves.easeOutBack.transform(_span(t, .58, 1));
    if (arrive > 0) {
      _phone(c, Offset.lerp(center, _me, arrive)!, ink, arrive, me: true);
      _phone(c, Offset.lerp(center, _peer, arrive)!, ink, arrive);
    }
  }

  // ------------------------------------------------------------- linking

  void _paintLinking(Canvas c, double t) {
    final arrive = AppMotion.easeOut.transform(t);
    final fromScan = from == JourneyStage.scanned;
    // Coming back from a failure (Try again), the phones already stand where
    // they belong: only the link grows again between them.
    final inPlace = fromScan || from == JourneyStage.failed;
    final me = inPlace ? _me : Offset.lerp(_hub, _me, arrive)!;
    final peer = inPlace ? _peer : Offset.lerp(_hub, _peer, arrive)!;
    if (fromScan && link != JourneyLink.sharedWifi) {
      // The ticked ring settles into the link's centre node.
      final center = Offset.lerp(_hub.translate(0, -22), _hub, arrive)!;
      final r = 26 - 20 * arrive;
      c.drawCircle(
        center,
        r,
        _stroke(Color.lerp(green, _linkColor, arrive)!, 2.2),
      );
    }
    final reveal = arrive;
    switch (link) {
      case JourneyLink.hotspot:
        _hotspot(c, me, peer, reveal);
      case JourneyLink.bluetooth:
        _bluetoothTether(c, me, peer, reveal);
      case JourneyLink.sharedWifi:
        _router(c, me, peer, reveal);
    }
    _phone(c, me, ink, 1, me: true);
    _phone(c, peer, ink, 1);
  }

  void _hotspot(Canvas c, Offset me, Offset peer, double reveal) {
    final color = amber;
    // The access point radiates from the other phone towards this one.
    for (var i = 0; i < 3; i++) {
      final phase = (loop.value + i / 3) % 1;
      final r = 22 + 70 * phase;
      final alpha = (1 - phase) * .55 * reveal;
      c.drawArc(
        Rect.fromCircle(center: peer, radius: r),
        math.pi - .62,
        1.24,
        false,
        _stroke(color.withValues(alpha: alpha), 2),
      );
    }
    // The beam, drawn from the AP outwards as it is discovered.
    final from = peer.translate(-22, 0);
    final to = me.translate(22, 0);
    _dashed(c, from, to, color.withValues(alpha: .35 * reveal), reveal);
    // Packets riding in.
    for (var i = 0; i < 3; i++) {
      final p = (loop.value * 1.5 + i / 3) % 1;
      if (p > reveal) continue;
      final pos = Offset.lerp(from, to, AppMotion.easeInOut.transform(p))!;
      c.drawCircle(pos, 3.2, _fill(color));
      c.drawCircle(pos, 7, _fill(color.withValues(alpha: .14)));
    }
    _node(c, Offset.lerp(from, to, .5)!, color, reveal);
  }

  void _bluetoothTether(Canvas c, Offset me, Offset peer, double reveal) {
    final color = _bluetooth;
    // Each phone's radio circling it, in opposite directions.
    for (final (center, dir) in [(me, 1.0), (peer, -1.0)]) {
      final a = dir * loop.value * 2 * math.pi;
      c.drawCircle(
        center,
        44,
        _stroke(color.withValues(alpha: .12 * reveal), 1.2),
      );
      for (var k = 0; k < 2; k++) {
        final ang = a + k * math.pi;
        c.drawCircle(
          center + Offset(math.cos(ang), math.sin(ang)) * 44,
          2.8,
          _fill(color.withValues(alpha: .9 * reveal)),
        );
      }
    }
    // A living tether: a wave that travels between them.
    final from = me.translate(22, 0);
    final to = peer.translate(-22, 0);
    final path = Path();
    const steps = 48;
    for (var i = 0; i <= steps; i++) {
      final f = i / steps;
      if (f > reveal) break;
      final x = from.dx + (to.dx - from.dx) * f;
      final envelope = math.sin(f * math.pi);
      final y =
          from.dy +
          math.sin(f * math.pi * 4 - loop.value * math.pi * 2) * 9 * envelope;
      i == 0 ? path.moveTo(x, y) : path.lineTo(x, y);
    }
    c.drawPath(path, _stroke(color.withValues(alpha: .85), 2.2));
    _node(c, Offset.lerp(from, to, .5)!, color, reveal);
  }

  void _router(Canvas c, Offset me, Offset peer, double reveal) {
    final color = amber;
    final hub = Offset.lerp(_hub, _routerAt, reveal)!;
    // The router both phones hang off.
    final body = RRect.fromRectAndRadius(
      Rect.fromCenter(center: hub, width: 46, height: 20),
      const Radius.circular(6),
    );
    c.drawRRect(body, _fill(color.withValues(alpha: .1 * reveal)));
    c.drawRRect(body, _stroke(color.withValues(alpha: reveal), 1.8));
    for (final dx in const [-12.0, 12.0]) {
      c.drawLine(
        hub.translate(dx, -10),
        hub.translate(dx * 1.3, -20),
        _stroke(color.withValues(alpha: reveal), 1.8),
      );
    }
    for (var i = 0; i < 2; i++) {
      final phase = (loop.value + i / 2) % 1;
      c.drawArc(
        Rect.fromCircle(center: hub.translate(0, -8), radius: 18 + 16 * phase),
        math.pi * 1.2,
        math.pi * .6,
        false,
        _stroke(color.withValues(alpha: (1 - phase) * .4 * reveal), 1.6),
      );
    }
    // Both legs, with traffic flowing down to each phone.
    for (final end in [me, peer]) {
      final from = hub.translate(0, 12);
      final to = end.translate(0, -34);
      _dashed(c, from, to, color.withValues(alpha: .32 * reveal), reveal);
      for (var i = 0; i < 2; i++) {
        final p = (loop.value * 1.3 + i / 2 + (end == me ? 0 : .25)) % 1;
        if (p > reveal) continue;
        c.drawCircle(Offset.lerp(from, to, p)!, 2.8, _fill(color));
      }
    }
  }

  // --------------------------------------------------------- established
  //
  // Each link locks in its own way, carrying on from the motion its linking
  // stage was making: the scene never cuts to a generic "done".

  void _paintEstablished(Canvas c, double t) {
    switch (link) {
      case JourneyLink.hotspot:
        _hotspotEstablished(c, t);
      case JourneyLink.bluetooth:
        _bluetoothEstablished(c, t);
      case JourneyLink.sharedWifi:
        _wifiEstablished(c, t);
    }
  }

  /// The access point's beam locks solid from the other phone to this one,
  /// the radiating arcs fold back into a steady signal mark on the AP, and
  /// this phone is reeled in along the beam.
  void _hotspotEstablished(Canvas c, double t) {
    final lock = AppMotion.easeOut.transform(_span(t, 0, .45));
    final reel = Curves.easeOutBack.transform(_span(t, .08, .62));
    final me = _me.translate(24 * reel, 0);
    final peer = _peer;
    final from = peer.translate(-22, 0);
    final to = me.translate(22, 0);
    final color = Color.lerp(amber, green, _span(t, .15, .55))!;
    // The arcs that were radiating towards this phone fold back into the AP
    // and stand as its signal mark.
    final fold = AppMotion.easeInOut.transform(_span(t, 0, .5));
    final markAt = peer.translate(0, -36);
    const liveStart = math.pi - .62;
    // The same heading as the mark below, a turn on: the arcs swing up over
    // the AP rather than down through the phone.
    const markStart = math.pi * 1.5 - .75;
    for (var i = 0; i < 3; i++) {
      final phase = (loop.value + i / 3) % 1;
      final live = 22 + 70 * phase;
      final mark = 6.0 + 6 * i;
      final alpha = (1 - phase) * .55 * (1 - fold) + fold;
      c.drawArc(
        Rect.fromCircle(
          center: Offset.lerp(peer, markAt, fold)!,
          radius: live + (mark - live) * fold,
        ),
        liveStart + (markStart - liveStart) * fold,
        1.24 + (1.5 - 1.24) * fold,
        false,
        _stroke(color.withValues(alpha: alpha.clamp(0.0, 1.0)), 2 + .4 * fold),
      );
    }
    c.drawCircle(markAt.translate(0, 3), 2.4 * fold, _fill(color));
    // The dashed beam hardens into a solid one, AP side first.
    _dashed(c, from, to, amber.withValues(alpha: .35 * (1 - lock)), 1);
    c.drawLine(from, Offset.lerp(from, to, lock)!, _stroke(color, 3));
    // The last packets in flight are swallowed by this phone.
    final swallow = 1 - _span(t, 0, .4);
    if (swallow > 0) {
      for (var i = 0; i < 3; i++) {
        final p = (loop.value * 1.5 + i / 3) % 1;
        final pos = Offset.lerp(from, to, AppMotion.easeInOut.transform(p))!;
        c.drawCircle(pos, 3.2, _fill(amber.withValues(alpha: swallow)));
      }
    }
    final mid = Offset.lerp(from, to, .5)!;
    _seal(c, mid, t, at: .38);
    // One broadcast arc out of the seal towards each phone.
    final out = _span(t, .5, 1);
    if (out > 0 && out < 1) {
      final r = 24 + 60 * AppMotion.easeOut.transform(out);
      for (final a in const [0.0, math.pi]) {
        c.drawArc(
          Rect.fromCircle(center: mid, radius: r),
          a - .7,
          1.4,
          false,
          _stroke(green.withValues(alpha: (1 - out) * .6), 2),
        );
      }
    }
    _phone(c, me, Color.lerp(ink, green, lock * .6)!, 1, me: true, lit: lock);
    _phone(c, peer, Color.lerp(ink, green, lock * .6)!, 1, lit: lock);
  }

  /// The travelling wave's amplitude settles into a straight, lit tether, and
  /// the two radio dots circling each phone spiral in and land in it.
  void _bluetoothEstablished(Canvas c, double t) {
    final settle = AppMotion.easeOut.transform(_span(t, 0, .5));
    final pull = Curves.easeOutBack.transform(_span(t, .05, .6));
    final me = _me.translate(16 * pull, 0);
    final peer = _peer.translate(-16 * pull, 0);
    final color = Color.lerp(_bluetooth, green, _span(t, .25, .6))!;
    // Orbits spiralling in: the radius closes, the dots fall into the phone.
    final fall = Curves.easeIn.transform(_span(t, 0, .55));
    for (final (center, dir) in [(me, 1.0), (peer, -1.0)]) {
      final radius = 44 * (1 - fall);
      final a = dir * (loop.value * 2 * math.pi + fall * math.pi * 1.5);
      if (radius > 1) {
        c.drawCircle(
          center,
          radius,
          _stroke(_bluetooth.withValues(alpha: .12 * (1 - fall)), 1.2),
        );
      }
      for (var k = 0; k < 2; k++) {
        final ang = a + k * math.pi;
        c.drawCircle(
          center + Offset(math.cos(ang), math.sin(ang)) * radius,
          2.8 * (1 - .5 * fall),
          _fill(_bluetooth.withValues(alpha: .9 * (1 - fall * fall))),
        );
      }
    }
    // The wave keeps travelling while its amplitude dies away.
    final from = me.translate(22, 0);
    final to = peer.translate(-22, 0);
    final path = Path();
    const steps = 48;
    final amp = 9 * (1 - settle);
    for (var i = 0; i <= steps; i++) {
      final f = i / steps;
      final x = from.dx + (to.dx - from.dx) * f;
      final y =
          from.dy +
          math.sin(f * math.pi * 4 - loop.value * math.pi * 2) *
              amp *
              math.sin(f * math.pi);
      i == 0 ? path.moveTo(x, y) : path.lineTo(x, y);
    }
    // A soft wider stroke under the line once it is straight: lit, not
    // blurred.
    if (settle > .2) {
      c.drawPath(path, _stroke(color.withValues(alpha: .16 * settle), 7));
    }
    c.drawPath(
      path,
      _stroke(color.withValues(alpha: .85 + .15 * settle), 2.2 + settle),
    );
    final mid = Offset.lerp(from, to, .5)!;
    // Two sparks run in from the phones along the straight tether and meet.
    final meet = _span(t, .32, .58);
    if (meet > 0 && meet < 1) {
      final e = AppMotion.easeInOut.transform(meet);
      for (final end in [from, to]) {
        c.drawCircle(Offset.lerp(end, mid, e)!, 3.4, _fill(color));
      }
    }
    _seal(c, mid, t, at: .52);
    // Bluetooth's own pulse language: short dotted rings.
    final halo = _span(t, .62, 1);
    if (halo > 0 && halo < 1) {
      for (var k = 0; k < 2; k++) {
        final h = (halo - k * .2).clamp(0.0, 1.0);
        if (h <= 0) continue;
        _dottedRing(
          c,
          mid,
          24 + 56 * AppMotion.easeOut.transform(h),
          green.withValues(alpha: (1 - h) * .7),
          2.6 - k * .6,
        );
      }
    }
    final lit = _span(t, .4, .7);
    _phone(c, me, Color.lerp(ink, green, lit * .6)!, 1, me: true, lit: lit);
    _phone(c, peer, Color.lerp(ink, green, lit * .6)!, 1, lit: lit);
  }

  /// Both legs of the router lock solid, one after the other, and the router
  /// itself becomes the seal: the network is what joined them.
  void _wifiEstablished(Canvas c, double t) {
    final hub = _routerAt;
    final legMe = AppMotion.easeOut.transform(_span(t, 0, .38));
    final legPeer = AppMotion.easeOut.transform(_span(t, .12, .5));
    for (final (end, lock, offset) in [
      (_me, legMe, 0.0),
      (_peer, legPeer, .25),
    ]) {
      final from = hub.translate(0, 12);
      final to = end.translate(0, -34);
      _dashed(c, from, to, amber.withValues(alpha: .32 * (1 - lock)), 1);
      final color = Color.lerp(amber, green, lock)!;
      c.drawLine(from, Offset.lerp(from, to, lock)!, _stroke(color, 2.6));
      // Traffic still in flight drains down to the phones.
      if (lock < 1) {
        for (var i = 0; i < 2; i++) {
          final p = (loop.value * 1.3 + i / 2 + offset) % 1;
          if (p < lock) continue;
          c.drawCircle(
            Offset.lerp(from, to, p)!,
            2.8,
            _fill(amber.withValues(alpha: 1 - lock)),
          );
        }
      }
    }
    // The router's own arcs stop sweeping and stand as a steady mark.
    final steady = AppMotion.easeOut.transform(_span(t, .1, .5));
    final routerColor = Color.lerp(amber, green, _span(t, .3, .6))!;
    for (var i = 0; i < 2; i++) {
      final phase = (loop.value + i / 2) % 1;
      final live = 18 + 16 * phase;
      final mark = 16.0 + 8 * i;
      final alpha = (1 - phase) * .4 * (1 - steady) + .9 * steady;
      c.drawArc(
        Rect.fromCircle(
          center: hub.translate(0, -8),
          radius: live + (mark - live) * steady,
        ),
        math.pi * 1.2,
        math.pi * .6,
        false,
        _stroke(
          routerColor.withValues(alpha: alpha.clamp(0.0, 1.0)),
          1.6 + .4 * steady,
        ),
      );
    }
    // The router body gives way to the seal in its place.
    final pop = _span(t, .45, .8);
    if (pop < 1) {
      final body = RRect.fromRectAndRadius(
        Rect.fromCenter(center: hub, width: 46, height: 20),
        const Radius.circular(6),
      );
      final fade = routerColor.withValues(alpha: 1 - pop);
      c.drawRRect(body, _fill(routerColor.withValues(alpha: .12 * (1 - pop))));
      c.drawRRect(body, _stroke(fade, 1.8));
      for (final dx in const [-12.0, 12.0]) {
        c.drawLine(
          hub.translate(dx, -10),
          hub.translate(dx * 1.3, -20),
          _stroke(fade, 1.8),
        );
      }
    }
    _seal(c, hub, t, at: .45, radius: 18);
    // Rings travel down the legs to each phone rather than out into the sky.
    final halo = _span(t, .62, 1);
    if (halo > 0 && halo < 1) {
      for (final end in [_me, _peer]) {
        final pos = Offset.lerp(
          hub.translate(0, 12),
          end.translate(0, -34),
          AppMotion.easeOut.transform(halo),
        )!;
        c.drawCircle(
          pos,
          4 + 6 * halo,
          _stroke(green.withValues(alpha: (1 - halo) * .8), 1.8),
        );
      }
    }
    _phone(
      c,
      _me,
      Color.lerp(ink, green, legMe * .6)!,
      1,
      me: true,
      lit: legMe,
    );
    _phone(c, _peer, Color.lerp(ink, green, legPeer * .6)!, 1, lit: legPeer);
  }

  /// The badge every link ends on: pops at [center] from [at], ticks, holds.
  void _seal(
    Canvas c,
    Offset center,
    double t, {
    required double at,
    double radius = 21,
  }) {
    final pop = Curves.easeOutBack.transform(_span(t, at, at + .36));
    if (pop <= 0) return;
    final r = radius * pop;
    c.drawCircle(center, r, _fill(surface));
    c.drawCircle(center, r, _fill(green.withValues(alpha: .18)));
    c.drawCircle(center, r, _stroke(green, 2.4));
    _tick(c, center, _span(t, at + .12, at + .44), green, radius * .38);
  }

  // -------------------------------------------------------------- failed
  //
  // Calm, and specific: what breaks is what the linking stage was showing.

  /// How far an established link had drawn this phone and the other one in
  /// (as x offsets) when this stage began. A link lost from there lets the
  /// phones go over the first half of the failure instead of jumping them
  /// back apart.
  (double, double) get _heldPull => from != JourneyStage.established
      ? (0, 0)
      : switch (link) {
          JourneyLink.hotspot => (24, 0),
          JourneyLink.bluetooth => (16, -16),
          JourneyLink.sharedWifi => (0, 0),
        };

  /// What is left of [_heldPull] at [t] of the failure.
  double _held(double t) => 1 - AppMotion.easeInOut.transform(_span(t, 0, .5));

  void _paintFailed(Canvas c, double t) {
    switch (link) {
      case JourneyLink.hotspot:
        _hotspotFailed(c, t);
      case JourneyLink.bluetooth:
        _bluetoothFailed(c, t);
      case JourneyLink.sharedWifi:
        _wifiFailed(c, t);
    }
  }

  /// The AP's arcs flicker out and the beam breaks short of this phone: the
  /// network was there, and this phone could not get onto it.
  void _hotspotFailed(Canvas c, double t) {
    final (meHeld, _) = _heldPull;
    final peer = _peer;
    // This phone recoils a little from the beam it could not catch.
    final recoil =
        math.sin(t * math.pi * 6) * 5 * math.pow(1 - t, 2).toDouble() -
        8 * AppMotion.easeOut.transform(_span(t, 0, .5));
    final me = _me.translate(recoil + meHeld * _held(t), 0);
    final from = peer.translate(-22, 0);
    final to = me.translate(22, 0);
    final broken = Color.lerp(amber, red, _span(t, 0, .35))!;
    // Arcs stutter and go out, one after another.
    for (var i = 0; i < 3; i++) {
      final out = _span(t, i * .12, .5 + i * .12);
      if (out >= 1) continue;
      final flicker = math.sin(t * 46 + i * 2.1) > -.2 ? 1.0 : .25;
      final phase = (loop.value + i / 3) % 1;
      c.drawArc(
        Rect.fromCircle(center: peer, radius: 22 + 70 * phase),
        math.pi - .62,
        1.24,
        false,
        _stroke(
          amber.withValues(alpha: (1 - phase) * .55 * (1 - out) * flicker),
          2,
        ),
      );
    }
    // What is left of the AP: a dim, still mark with no waves.
    final markAt = peer.translate(0, -36);
    final settle = _span(t, .5, .9);
    if (settle > 0) {
      for (var i = 0; i < 3; i++) {
        c.drawArc(
          Rect.fromCircle(center: markAt, radius: 6.0 + 6 * i),
          -math.pi / 2 - .75,
          1.5,
          false,
          _stroke(ink.withValues(alpha: .3 * settle), 2),
        );
      }
    }
    // The beam reaches part-way, then breaks: its far end drops away.
    final reach = 1 - .48 * AppMotion.easeOut.transform(_span(t, .05, .45));
    _dashed(
      c,
      from,
      Offset.lerp(from, to, reach)!,
      broken.withValues(alpha: .55),
      1,
    );
    final drop = _span(t, .1, .85);
    if (drop < 1) {
      final fall = Offset(-6 * drop, 44 * drop * drop);
      c.drawLine(
        Offset.lerp(from, to, .62)! + fall,
        to + fall + Offset(0, 14 * drop),
        _stroke(broken.withValues(alpha: .6 * (1 - drop)), 1.8),
      );
    }
    _calmMark(c, Offset.lerp(from, to, .5)!.translate(0, -48), t);
    _phone(c, me, ink.withValues(alpha: .8), 1, me: true);
    _phone(c, peer, ink.withValues(alpha: .55), 1);
  }

  /// The wave loses its coherence into static, and each phone's orbiting
  /// radio drifts away from the other.
  void _bluetoothFailed(Canvas c, double t) {
    final drift = AppMotion.easeOut.transform(_span(t, 0, .7));
    final (meHeld, peerHeld) = _heldPull;
    final held = _held(t);
    final me = _me.translate(-12 * drift + meHeld * held, 0);
    final peer = _peer.translate(12 * drift + peerHeld * held, 0);
    // Orbits drift outwards and dim: two radios no longer finding each other.
    for (final (center, dir) in [(me, 1.0), (peer, -1.0)]) {
      final radius = 44 + 16 * drift;
      final a = dir * loop.value * 2 * math.pi;
      c.drawCircle(
        center,
        radius,
        _stroke(_bluetooth.withValues(alpha: .12 * (1 - .6 * drift)), 1.2),
      );
      for (var k = 0; k < 2; k++) {
        final ang = a + k * math.pi;
        c.drawCircle(
          center + Offset(math.cos(ang), math.sin(ang)) * radius,
          2.8,
          _fill(_bluetooth.withValues(alpha: .9 - .6 * drift)),
        );
      }
    }
    // The wave turns to static: jitter grows, the line falls apart into
    // fragments, and the noise settles into a still, broken trace.
    final from = me.translate(22, 0);
    final to = peer.translate(-22, 0);
    final color = Color.lerp(_bluetooth, red, _span(t, 0, .4))!;
    final decoherence = AppMotion.easeOut.transform(_span(t, 0, .5));
    final live = 1 - _span(t, .55, 1);
    final frame = (loop.value * 24).floor();
    final paint = _stroke(
      color.withValues(alpha: .85 - .45 * _span(t, .4, 1)),
      2,
    );
    const steps = 48;
    Offset? last;
    for (var i = 0; i <= steps; i++) {
      final f = i / steps;
      final x = from.dx + (to.dx - from.dx) * f;
      final envelope = math.sin(f * math.pi);
      final coherent =
          math.sin(f * math.pi * 4 - loop.value * math.pi * 2) * 9 * envelope;
      final noise =
          (_hash(i, frame) - .5) * 22 * envelope * live +
          (_hash(i, 7) - .5) * 8 * envelope;
      final y = from.dy + coherent * (1 - decoherence) + noise * decoherence;
      final p = Offset(x, y);
      // Gaps open up as it decays, the middle first.
      final gapChance = decoherence * (.25 + .55 * envelope);
      final seed = 3 + (live > 0 ? frame % 3 : 0);
      if (last != null && _hash(i, seed) > gapChance) {
        c.drawLine(last, p, paint);
      }
      last = p;
    }
    _calmMark(c, Offset.lerp(from, to, .5)!.translate(0, -48), t);
    _phone(c, me, ink.withValues(alpha: .8), 1, me: true);
    _phone(c, peer, ink.withValues(alpha: .55), 1);
  }

  /// The router stays up and this phone's leg stays lit, but the other
  /// phone's leg goes dark: the network is fine, the other phone is not on it.
  void _wifiFailed(Canvas c, double t) {
    final hub = _routerAt;
    final dim = _span(t, 0, .6);
    final routerColor = amber.withValues(alpha: 1 - .4 * dim);
    final body = RRect.fromRectAndRadius(
      Rect.fromCenter(center: hub, width: 46, height: 20),
      const Radius.circular(6),
    );
    c.drawRRect(body, _fill(amber.withValues(alpha: .1)));
    c.drawRRect(body, _stroke(routerColor, 1.8));
    for (final dx in const [-12.0, 12.0]) {
      c.drawLine(
        hub.translate(dx, -10),
        hub.translate(dx * 1.3, -20),
        _stroke(routerColor, 1.8),
      );
    }
    // The router's sweep winds down.
    for (var i = 0; i < 2; i++) {
      final phase = (loop.value + i / 2) % 1;
      c.drawArc(
        Rect.fromCircle(center: hub.translate(0, -8), radius: 18 + 16 * phase),
        math.pi * 1.2,
        math.pi * .6,
        false,
        _stroke(amber.withValues(alpha: (1 - phase) * .4 * (1 - dim)), 1.6),
      );
    }
    // This phone's leg: still there, quiet.
    final legFrom = hub.translate(0, 12);
    _dashed(c, legFrom, _me.translate(0, -34), amber.withValues(alpha: .32), 1);
    // Theirs flickers, reddens and goes dark from the router down.
    final peerTo = _peer.translate(0, -34);
    final dark = Curves.easeIn.transform(_span(t, .1, .7));
    final flicker = t < .7 && math.sin(t * 52) < -.3 ? .3 : 1.0;
    final legColor = Color.lerp(amber, red, _span(t, 0, .3))!;
    final lit = Offset.lerp(legFrom, peerTo, dark)!;
    c.drawLine(legFrom, lit, _stroke(ink.withValues(alpha: .12), 1.6));
    _dashed(
      c,
      lit,
      peerTo,
      legColor.withValues(alpha: .45 * (1 - dark) * flicker),
      1,
    );
    _calmMark(c, Offset.lerp(legFrom, peerTo, .5)!.translate(26, 0), t);
    _phone(c, _me, ink.withValues(alpha: .8), 1, me: true);
    _phone(c, _peer, ink.withValues(alpha: .8 - .45 * dark), 1);
  }

  /// A calm cross in a ring rather than an alarm.
  void _calmMark(Canvas c, Offset center, double t) {
    final mark = Curves.easeOutBack.transform(_span(t, .35, .75));
    if (mark <= 0) return;
    final r = 17 * mark;
    c.drawCircle(center, r, _fill(surface));
    c.drawCircle(center, r, _fill(red.withValues(alpha: .12)));
    c.drawCircle(
      center,
      r,
      _stroke(red.withValues(alpha: mark.clamp(0.0, 1.0)), 2),
    );
    final s = 6 * mark;
    c.drawLine(
      center.translate(-s, -s),
      center.translate(s, s),
      _stroke(red, 2.4),
    );
    c.drawLine(
      center.translate(s, -s),
      center.translate(-s, s),
      _stroke(red, 2.4),
    );
  }

  /// A cheap, stable pseudo-random value in [0, 1) for a pair of integers.
  static double _hash(int a, int b) {
    var h = (a * 374761393 + b * 668265263) & 0x7FFFFFFF;
    h = ((h ^ (h >> 13)) * 1274126177) & 0x7FFFFFFF;
    h = h ^ (h >> 16);
    return (h & 0xFFFF) / 0x10000;
  }

  void _dottedRing(Canvas c, Offset center, double r, Color color, double dot) {
    final count = (r * 2 * math.pi / 9).floor().clamp(10, 80);
    final paint = _fill(color);
    for (var i = 0; i < count; i++) {
      final a = i / count * math.pi * 2;
      c.drawCircle(
        center + Offset(math.cos(a), math.sin(a)) * r,
        dot / 2,
        paint,
      );
    }
  }

  // -------------------------------------------------------------- pieces

  void _phone(
    Canvas c,
    Offset center,
    Color color,
    double appear, {
    bool me = false,
    double lit = 0,
  }) {
    if (appear <= 0) return;
    final scale = appear.clamp(0.0, 1.2);
    final rect = Rect.fromCenter(
      center: center,
      width: 34 * scale,
      height: 60 * scale,
    );
    final rr = RRect.fromRectAndRadius(rect, Radius.circular(7 * scale));
    c.drawRRect(rr, _fill(surface));
    c.drawRRect(
      rr,
      _fill((me ? amber : color).withValues(alpha: .06 + .1 * lit)),
    );
    c.drawRRect(
      rr,
      _stroke(color.withValues(alpha: appear.clamp(0.0, 1.0)), 2),
    );
    // Speaker slot and a screen glow; "me" carries a small amber dot.
    c.drawLine(
      center.translate(-5 * scale, -24 * scale),
      center.translate(5 * scale, -24 * scale),
      _stroke(color.withValues(alpha: .7 * appear.clamp(0.0, 1.0)), 1.6),
    );
    if (me) {
      c.drawCircle(center.translate(0, 18 * scale), 3 * scale, _fill(amber));
    }
  }

  void _node(Canvas c, Offset center, Color color, double reveal) {
    final breath = .5 - .5 * math.cos(loop.value * 2 * math.pi * 2);
    c.drawCircle(
      center,
      7 + 3 * breath,
      _fill(color.withValues(alpha: .14 * reveal)),
    );
    c.drawCircle(center, 4.2, _fill(color.withValues(alpha: reveal)));
  }

  void _dashed(Canvas c, Offset from, Offset to, Color color, double reveal) {
    final total = (to - from).distance;
    final dir = (to - from) / total;
    const dash = 6.0, gap = 6.0;
    final shift = (loop.value * (dash + gap) * 4) % (dash + gap);
    final paint = _stroke(color, 1.8);
    for (var d = -shift; d < total * reveal; d += dash + gap) {
      final a = from + dir * d.clamp(0.0, total);
      final b = from + dir * (d + dash).clamp(0.0, total * reveal);
      if ((b - a).distance > .5) c.drawLine(a, b, paint);
    }
  }

  void _tick(Canvas c, Offset center, double t, Color color, double size) {
    if (t <= 0) return;
    final d = mirrored ? -1.0 : 1.0;
    final path = Path()
      ..moveTo(center.dx - d * size * .85, center.dy + size * .05)
      ..lineTo(center.dx - d * size * .25, center.dy + size * .62)
      ..lineTo(center.dx + d * size * .9, center.dy - size * .6);
    final metric = path.computeMetrics().first;
    c.drawPath(
      metric.extractPath(0, metric.length * AppMotion.easeOut.transform(t)),
      _stroke(color, 3.2),
    );
  }

  @override
  bool shouldRepaint(_JourneyPainter old) =>
      old.stage != stage ||
      old.from != from ||
      old.link != link ||
      old.amber != amber ||
      old.green != green ||
      old.red != red ||
      old.ink != ink ||
      old.surface != surface ||
      old.mirrored != mirrored;
}
