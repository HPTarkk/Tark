import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../../core/l10n/extension.dart';
import '../../../../core/motion/app_motion.dart';
import '../../../../core/theme/app_colors.dart';
import '../../../../core/utils/logger.dart';
import '../../domain/service/hotspot_control.dart';

/// How the Wi-Fi page was left.
enum HotspotWifiOffResult {
  /// The radio went off while the page was up.
  wifiOff,

  /// The user chose to host with Wi-Fi still on (the button, close or back).
  skipped,
}

/// The full-screen "turn Wi-Fi off" ask a hotspot host sees as hosting starts.
///
/// ## Why a page and not the inline card
///
/// With Wi-Fi on, Android can hand the radio back to a saved network at any
/// moment and quietly shut the hotspot down, and the people on the other end
/// hear nothing until the host notices. The inline card on the Walkie host
/// screen was easy to scroll past and never showed in Rooms at all. This page
/// is shown once each time the phone starts hosting while Wi-Fi is on,
/// whatever the chipset claims about running both, because phones that claim
/// they can still drop the hotspot.
///
/// ## It never blocks hosting
///
/// It sits *over* the host screen while the hotspot comes up underneath, so a
/// Room hand-off keeps its own timer and the other phone is never left waiting
/// on someone reading. Wi-Fi off closes it by itself with a check mark;
/// "Continue anyway", close and back all leave with
/// [HotspotWifiOffResult.skipped]. Nothing is remembered: the next time this
/// phone hosts with Wi-Fi on, it asks again.
///
/// ## Why an overlay and not a route
///
/// The other phone usually joins within seconds, and the host screen then
/// navigates into the channel. A route pushed over the host screen would be
/// swept away with it, right when the advice matters most. [show] puts the
/// page on the root navigator's overlay instead, which page changes leave
/// alone, and gives it the same rise from the bottom a full-screen dialog has.
///
/// No app can switch Wi-Fi off itself on Android 10+ (`setWifiEnabled` is a
/// no-op), so the button raises the system's own Wi-Fi panel over the app.
class HotspotWifiOffPage extends StatefulWidget {
  /// Reads whether the Wi-Fi radio is on right now.
  final Future<bool> Function() readWifiOn;

  /// Puts the Wi-Fi switch in front of the user.
  final Future<void> Function() openWifi;

  /// Called once, with how the page was left.
  final ValueChanged<HotspotWifiOffResult> onDone;

  /// How often the radio is re-read while the page is up. The system panel
  /// floats over the app without pausing it, so there is no resume to wait
  /// for.
  final Duration pollEvery;

  const HotspotWifiOffPage({
    super.key,
    required this.readWifiOn,
    required this.openWifi,
    required this.onDone,
    this.pollEvery = const Duration(seconds: 1),
  });

  /// Shows the page over everything and completes with how it was left.
  static Future<HotspotWifiOffResult> show(
    BuildContext context, {
    required Future<bool> Function() readWifiOn,
    required Future<void> Function() openWifi,
  }) {
    final overlay = Navigator.of(context, rootNavigator: true).overlay!;
    final done = Completer<HotspotWifiOffResult>();
    late final OverlayEntry entry;
    entry = OverlayEntry(
      builder: (_) => _OverlayPresenter(
        onGone: (result) {
          entry.remove();
          entry.dispose();
          done.complete(result);
        },
        builder: (close) => HotspotWifiOffPage(
          readWifiOn: readWifiOn,
          openWifi: openWifi,
          onDone: close,
        ),
      ),
    );
    overlay.insert(entry);
    Logger.diagnostic('hotspot: wifi-off page shown');
    return done.future.then((result) {
      Logger.diagnostic('hotspot: wifi-off page ${result.name}');
      return result;
    });
  }

  /// Shows the page when [host]'s phone has Wi-Fi on, and returns how it was
  /// left. Returns null without showing anything when Wi-Fi is already off or
  /// cannot be read (iOS, desktop).
  static Future<HotspotWifiOffResult?> showIfWifiOn(
    BuildContext context,
    HotspotHost host,
  ) async {
    final HotspotWifiAdvice advice;
    try {
      advice = await host.wifiAdvice();
    } catch (e) {
      Logger.log('Wi-Fi state read failed: $e');
      return null;
    }
    if (!advice.wifiEnabled || !context.mounted) return null;
    return show(
      context,
      readWifiOn: () async => (await host.wifiAdvice()).wifiEnabled,
      openWifi: () async {
        await host.openWifiPanel();
      },
    );
  }

  @override
  State<HotspotWifiOffPage> createState() => _HotspotWifiOffPageState();
}

class _HotspotWifiOffPageState extends State<HotspotWifiOffPage>
    with TickerProviderStateMixin, WidgetsBindingObserver {
  /// The ambient loop: signal rings leaving the phone, and the Wi-Fi badge
  /// tugging at it. Stopped under reduced motion and once Wi-Fi is off.
  late final AnimationController _ambient = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 2600),
  );

  /// Wi-Fi on → off: the slash drawn across the badge, the tug line let go,
  /// the rings turning green and the check mark landing.
  late final AnimationController _resolve = AnimationController(
    vsync: this,
    duration: AppMotion.entrance * 2,
  );

  /// The hero's own entrance, ahead of the text below it.
  late final AnimationController _heroIn = AnimationController(
    vsync: this,
    duration: AppMotion.sheet * 2,
  )..forward();

  Timer? _poll;
  bool _reading = false;
  bool _wifiOff = false;
  bool _leaving = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _poll = Timer.periodic(widget.pollEvery, (_) => _check());
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _syncAmbient();
  }

  void _syncAmbient() {
    final run = !_wifiOff && !AppMotion.reduced(context);
    if (run && !_ambient.isAnimating) {
      _ambient.repeat();
    } else if (!run && _ambient.isAnimating) {
      _ambient.stop();
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Full settings (Android 9 and older) does background the app; read the
    // radio the moment the user is back rather than up to a second later.
    if (state == AppLifecycleState.resumed) _check();
  }

  Future<void> _check() async {
    if (_reading || _wifiOff || !mounted) return;
    _reading = true;
    bool on;
    try {
      on = await widget.readWifiOn();
    } catch (e) {
      Logger.log('Wi-Fi state read failed: $e');
      on = true;
    } finally {
      _reading = false;
    }
    if (!mounted || on || _wifiOff) return;
    _onWifiOff();
  }

  void _onWifiOff() {
    _poll?.cancel();
    HapticFeedback.mediumImpact();
    setState(() => _wifiOff = true);
    _syncAmbient();
    _resolve.forward();
    // Held long enough to read the check mark and the green status, then out
    // on its own: the user already did the one thing this page asked for.
    Timer(AppMotion.confirmHold, () => _leave(HotspotWifiOffResult.wifiOff));
  }

  void _leave(HotspotWifiOffResult result) {
    if (_leaving || !mounted) return;
    _leaving = true;
    widget.onDone(result);
  }

  Future<void> _openWifi() async {
    try {
      await widget.openWifi();
    } catch (e) {
      Logger.log('Wi-Fi panel failed: $e');
    }
    // Some panels answer instantly; don't wait a whole tick to notice.
    unawaited(_check());
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _poll?.cancel();
    _ambient.dispose();
    _resolve.dispose();
    _heroIn.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final s = context.getString;
    final reduced = AppMotion.reduced(context);
    final amber = AppColors.amber;
    final green = AppColors.green;
    return _BackAsSkip(
      onBack: () => _leave(HotspotWifiOffResult.skipped),
      child: Scaffold(
        backgroundColor: AppColors.background,
        body: Stack(
          children: [
            // A warm wash behind the hero that cools to green once it is done.
            // A static gradient crossfaded by colour, so it costs nothing per
            // frame while the hero animates.
            Positioned.fill(
              child: AnimatedContainer(
                duration: AppMotion.entrance,
                curve: AppMotion.easeOut,
                decoration: BoxDecoration(
                  gradient: RadialGradient(
                    center: const Alignment(0, -0.62),
                    radius: 0.95,
                    colors: [
                      (_wifiOff ? green : amber).withValues(alpha: 0.16),
                      AppColors.background.withValues(alpha: 0),
                    ],
                  ),
                ),
              ),
            ),
            SafeArea(
              child: Column(
                children: [
                  Align(
                    alignment: AlignmentDirectional.centerStart,
                    child: Padding(
                      padding: const EdgeInsetsDirectional.only(
                        start: 8,
                        top: 4,
                      ),
                      child: IconButton(
                        key: const ValueKey('hotspot-wifi-off-close'),
                        tooltip: MaterialLocalizations.of(
                          context,
                        ).closeButtonTooltip,
                        icon: Icon(
                          Icons.close_rounded,
                          color: AppColors.textSecondary,
                        ),
                        onPressed: () => _leave(HotspotWifiOffResult.skipped),
                      ),
                    ),
                  ),
                  Expanded(
                    child: SingleChildScrollView(
                      padding: const EdgeInsets.fromLTRB(28, 0, 28, 16),
                      child: Column(
                        children: [
                          _HeroEntrance(
                            animation: _heroIn,
                            reduced: reduced,
                            child: _RadioHero(
                              ambient: _ambient,
                              resolve: _resolve,
                              amber: amber,
                              green: green,
                            ),
                          ),
                          const SizedBox(height: 12),
                          _StatusPill(
                            wifiOff: _wifiOff,
                            onLabel: s.hotspot_wifi_off_page_status_on,
                            offLabel: s.hotspot_wifi_off_page_status_off,
                          ),
                          const SizedBox(height: 18),
                          StaggeredEntrance(
                            builder: (context, children) =>
                                Column(children: children),
                            children: [
                              Text(
                                s.hotspot_wifi_off_page_title,
                                textAlign: TextAlign.center,
                                style: TextStyle(
                                  color: AppColors.textPrimary,
                                  fontSize: 22,
                                  fontWeight: FontWeight.w800,
                                  height: 1.3,
                                ),
                              ),
                              Padding(
                                padding: const EdgeInsets.only(top: 10),
                                child: Text(
                                  s.hotspot_wifi_off_page_body,
                                  textAlign: TextAlign.center,
                                  style: TextStyle(
                                    color: AppColors.textSecondary,
                                    fontSize: 14,
                                    height: 1.55,
                                  ),
                                ),
                              ),
                              const SizedBox(height: 18),
                              _Point(
                                icon: Icons.wifi_tethering_rounded,
                                tint: amber,
                                text: s.hotspot_wifi_off_page_point_steady,
                              ),
                              _Point(
                                icon: Icons.graphic_eq_rounded,
                                tint: amber,
                                text: s.hotspot_wifi_off_page_point_clear,
                              ),
                              _Point(
                                icon: Icons.verified_rounded,
                                tint: green,
                                text: s.hotspot_wifi_off_page_point_channel,
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(24, 8, 24, 16),
                    child: Column(
                      children: [
                        _PrimaryAction(
                          done: _wifiOff,
                          label: s.hotspot_wifi_off_page_action,
                          doneLabel: s.hotspot_wifi_off_page_done,
                          onTap: _openWifi,
                        ),
                        const SizedBox(height: 6),
                        AnimatedOpacity(
                          opacity: _wifiOff ? 0 : 1,
                          duration: AppMotion.chip,
                          curve: AppMotion.easeOut,
                          child: TextButton(
                            key: const ValueKey('hotspot-wifi-off-skip'),
                            onPressed: _wifiOff
                                ? null
                                : () => _leave(HotspotWifiOffResult.skipped),
                            child: Text(
                              s.hotspot_wifi_off_page_skip,
                              style: TextStyle(
                                color: AppColors.textSecondary,
                                fontSize: 14,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Runs the page's own entrance and exit around [builder], since an overlay
/// entry gets no route transition. The same rise from the bottom as a
/// full-screen dialog, on the drawer curve; reduced motion keeps only the
/// fade.
class _OverlayPresenter extends StatefulWidget {
  final Widget Function(ValueChanged<HotspotWifiOffResult> close) builder;
  final ValueChanged<HotspotWifiOffResult> onGone;

  const _OverlayPresenter({required this.builder, required this.onGone});

  @override
  State<_OverlayPresenter> createState() => _OverlayPresenterState();
}

class _OverlayPresenterState extends State<_OverlayPresenter>
    with SingleTickerProviderStateMixin {
  late final AnimationController _show = AnimationController(
    vsync: this,
    duration: AppMotion.sheet * 1.5,
    reverseDuration: AppMotion.sheet,
  )..forward();

  late final Widget _page = widget.builder(_close);
  bool _closing = false;

  Future<void> _close(HotspotWifiOffResult result) async {
    if (_closing) return;
    _closing = true;
    await _show.reverse();
    widget.onGone(result);
  }

  @override
  void dispose() {
    _show.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final curved = CurvedAnimation(
      parent: _show,
      curve: AppMotion.drawer,
      reverseCurve: AppMotion.drawer.flipped,
    );
    final faded = FadeTransition(opacity: curved, child: _page);
    if (AppMotion.reduced(context)) return faded;
    return SlideTransition(
      position: Tween<Offset>(
        begin: const Offset(0, 1),
        end: Offset.zero,
      ).animate(curved),
      child: faded,
    );
  }
}

/// Android back skips the page, like its close button, instead of popping
/// the screen underneath. Only where a [Router] owns the back button, which
/// is everywhere in the app.
class _BackAsSkip extends StatelessWidget {
  final VoidCallback onBack;
  final Widget child;

  const _BackAsSkip({required this.onBack, required this.child});

  @override
  Widget build(BuildContext context) {
    if (Router.maybeOf(context)?.backButtonDispatcher == null) return child;
    return BackButtonListener(
      onBackButtonPressed: () async {
        onBack();
        return true;
      },
      child: child,
    );
  }
}

/// Scales the hero up from just under full size as it fades in. Starts at
/// 0.9, not 0: nothing real grows out of nothing.
class _HeroEntrance extends StatelessWidget {
  final Animation<double> animation;
  final bool reduced;
  final Widget child;

  const _HeroEntrance({
    required this.animation,
    required this.reduced,
    required this.child,
  });

  @override
  Widget build(BuildContext context) {
    final curved = CurvedAnimation(parent: animation, curve: AppMotion.easeOut);
    final faded = FadeTransition(opacity: curved, child: child);
    if (reduced) return faded;
    return ScaleTransition(
      scale: Tween<double>(begin: 0.9, end: 1).animate(curved),
      child: faded,
    );
  }
}

/// The picture of the problem: this phone in the middle sending out its
/// hotspot, and the Wi-Fi badge beside it pulling at the same radio. When
/// Wi-Fi goes off, a slash crosses the badge, the pull lets go, the rings turn
/// green and a check mark lands on the phone.
///
/// Floor-device budget: one painter driven through `repaint:` (no rebuilds
/// per frame), strokes and fills only, no blur or clipping.
class _RadioHero extends StatelessWidget {
  final AnimationController ambient;
  final AnimationController resolve;
  final Color amber;
  final Color green;

  static const double _size = 196;
  static const double _core = 78;
  static const double _badge = 46;

  /// Where the Wi-Fi badge sits, as an offset from the centre. Up and to the
  /// start side, so in either reading direction it is met first.
  static const Offset _badgeAt = Offset(-64, -54);

  const _RadioHero({
    required this.ambient,
    required this.resolve,
    required this.amber,
    required this.green,
  });

  @override
  Widget build(BuildContext context) {
    final rtl = Directionality.of(context) == TextDirection.rtl;
    final badgeAt = Offset(rtl ? -_badgeAt.dx : _badgeAt.dx, _badgeAt.dy);
    final done = CurvedAnimation(parent: resolve, curve: AppMotion.easeOut);
    return RepaintBoundary(
      child: SizedBox(
        width: _size,
        height: _size,
        child: Stack(
          alignment: Alignment.center,
          children: [
            Positioned.fill(
              child: CustomPaint(
                painter: _HeroPainter(
                  ambient: ambient,
                  resolve: resolve,
                  amber: amber,
                  green: green,
                  line: AppColors.textSecondary,
                  badgeAt: badgeAt,
                  badgeRadius: _badge / 2,
                  coreRadius: _core / 2,
                ),
              ),
            ),
            // The phone: hotspot glyph, crossfading to a check mark.
            AnimatedBuilder(
              animation: done,
              builder: (context, child) {
                final c = Color.lerp(amber, green, done.value)!;
                return Container(
                  width: _core,
                  height: _core,
                  decoration: BoxDecoration(
                    color: AppColors.card,
                    shape: BoxShape.circle,
                    border: Border.all(color: c, width: 2.4),
                    boxShadow: [
                      BoxShadow(
                        color: c.withValues(alpha: 0.28),
                        blurRadius: 24,
                        spreadRadius: 1,
                      ),
                    ],
                  ),
                  child: child,
                );
              },
              child: _CoreGlyph(resolve: resolve, amber: amber, green: green),
            ),
            Transform.translate(
              offset: badgeAt,
              child: AnimatedBuilder(
                animation: done,
                builder: (context, child) => Transform.scale(
                  // The badge steps back once it has been dealt with.
                  scale: 1 - 0.14 * done.value,
                  child: Opacity(opacity: 1 - 0.45 * done.value, child: child),
                ),
                child: Container(
                  width: _badge,
                  height: _badge,
                  decoration: BoxDecoration(
                    color: AppColors.card,
                    shape: BoxShape.circle,
                    border: Border.all(color: AppColors.border, width: 1.4),
                  ),
                  child: Icon(
                    Icons.wifi_rounded,
                    size: 22,
                    color: AppColors.textPrimary,
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

/// The phone's glyph. The hotspot icon leaves as the check mark arrives, and
/// the check mark is the one element in the app allowed to overshoot.
class _CoreGlyph extends StatelessWidget {
  final AnimationController resolve;
  final Color amber;
  final Color green;

  const _CoreGlyph({
    required this.resolve,
    required this.amber,
    required this.green,
  });

  @override
  Widget build(BuildContext context) {
    final out = CurvedAnimation(
      parent: resolve,
      curve: const Interval(0.25, 0.5, curve: AppMotion.easeOut),
    );
    final check = CurvedAnimation(
      parent: resolve,
      curve: const Interval(0.45, 1, curve: Curves.easeOutBack),
    );
    return Stack(
      alignment: Alignment.center,
      children: [
        FadeTransition(
          opacity: ReverseAnimation(out),
          child: ScaleTransition(
            scale: Tween<double>(begin: 1, end: 0.7).animate(out),
            child: Icon(Icons.wifi_tethering_rounded, color: amber, size: 38),
          ),
        ),
        FadeTransition(
          opacity: CurvedAnimation(
            parent: resolve,
            curve: const Interval(0.45, 0.7),
          ),
          child: ScaleTransition(
            scale: Tween<double>(begin: 0.4, end: 1).animate(check),
            child: Icon(Icons.check_rounded, color: green, size: 42),
          ),
        ),
      ],
    );
  }
}

class _HeroPainter extends CustomPainter {
  final Animation<double> ambient;
  final Animation<double> resolve;
  final Color amber;
  final Color green;
  final Color line;
  final Offset badgeAt;
  final double badgeRadius;
  final double coreRadius;

  _HeroPainter({
    required this.ambient,
    required this.resolve,
    required this.amber,
    required this.green,
    required this.line,
    required this.badgeAt,
    required this.badgeRadius,
    required this.coreRadius,
  }) : super(repaint: Listenable.merge([ambient, resolve]));

  @override
  void paint(Canvas canvas, Size size) {
    final t = ambient.value;
    final r = AppMotion.easeOut.transform(resolve.value);
    final centre = size.center(Offset.zero);
    final ring = Color.lerp(amber, green, r)!;
    final maxRadius = size.shortestSide / 2 - 2;

    // Signal rings leaving the phone. Three, evenly out of phase, so there is
    // always one being born and one fading at the edge. Once resolved they
    // settle into three calm, still rings instead of stopping mid-flight.
    for (var i = 0; i < 3; i++) {
      final live = (t + i / 3) % 1.0;
      final still = (i + 1) / 3.6;
      final phase = live + (still - live) * r;
      final radius = coreRadius + (maxRadius - coreRadius) * phase;
      final fade = (1 - phase) * (1 - r) + 0.45 * (1 - phase * 0.6) * r;
      canvas.drawCircle(
        centre,
        radius,
        Paint()
          ..color = ring.withValues(alpha: (fade * 0.55).clamp(0.0, 1.0))
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2,
      );
    }

    // The pull: a dashed line from the Wi-Fi badge to the phone, with a pulse
    // of amber travelling along it towards the phone. It fades out as Wi-Fi
    // goes off, which is the pull letting go.
    final from = centre + badgeAt;
    final dir = centre - from;
    final length = dir.distance;
    if (length > 0 && r < 1) {
      final unit = dir / length;
      final start = from + unit * (badgeRadius + 4);
      final end = centre - unit * (coreRadius + 6);
      final span = (end - start).distance;
      final dash = Paint()
        ..color = line.withValues(alpha: 0.55 * (1 - r))
        ..strokeWidth = 2
        ..strokeCap = StrokeCap.round;
      for (double d = 0; d < span; d += 9) {
        final a = start + unit * d;
        final b = start + unit * math.min(d + 4, span);
        canvas.drawLine(a, b, dash);
      }
      final pulse = start + unit * (span * ((t * 2) % 1.0));
      canvas.drawCircle(
        pulse,
        3.4,
        Paint()..color = amber.withValues(alpha: 0.9 * (1 - r)),
      );
    }

    // The slash across the Wi-Fi badge, drawn in from one end.
    final slash = ((resolve.value - 0.05) / 0.35).clamp(0.0, 1.0);
    if (slash > 0) {
      final k = badgeRadius * 0.72;
      final a = from + Offset(-k, -k);
      final b = from + Offset(k, k);
      final tip = Offset.lerp(a, b, AppMotion.easeOut.transform(slash))!;
      canvas.drawLine(
        a,
        tip,
        Paint()
          ..color = AppColors.red
          ..strokeWidth = 3.2
          ..strokeCap = StrokeCap.round,
      );
    }
  }

  @override
  bool shouldRepaint(_HeroPainter old) =>
      old.amber != amber ||
      old.green != green ||
      old.line != line ||
      old.badgeAt != badgeAt;
}

/// "Wi-Fi is on" with a live amber dot, swapped for a green "all set" the
/// moment the radio goes off.
class _StatusPill extends StatelessWidget {
  final bool wifiOff;
  final String onLabel;
  final String offLabel;

  const _StatusPill({
    required this.wifiOff,
    required this.onLabel,
    required this.offLabel,
  });

  @override
  Widget build(BuildContext context) {
    final tint = wifiOff ? AppColors.green : AppColors.amber;
    return AnimatedContainer(
      duration: AppMotion.card,
      curve: AppMotion.easeOut,
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
      decoration: BoxDecoration(
        color: tint.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(40),
        border: Border.all(color: tint.withValues(alpha: 0.45)),
      ),
      child: AnimatedSize(
        duration: AppMotion.card,
        curve: AppMotion.easeOut,
        child: AnimatedSwitcher(
          duration: AppMotion.card,
          switchInCurve: AppMotion.easeOut,
          switchOutCurve: AppMotion.leaving,
          child: Row(
            key: ValueKey(wifiOff),
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                wifiOff ? Icons.wifi_off_rounded : Icons.wifi_rounded,
                size: 15,
                color: tint,
              ),
              const SizedBox(width: 7),
              Text(
                wifiOff ? offLabel : onLabel,
                style: TextStyle(
                  color: tint,
                  fontSize: 12.5,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// One reason, as an icon and a line.
class _Point extends StatelessWidget {
  final IconData icon;
  final Color tint;
  final String text;

  const _Point({required this.icon, required this.tint, required this.text});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        decoration: BoxDecoration(
          color: AppColors.card,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: AppColors.border),
        ),
        child: Row(
          children: [
            Container(
              width: 32,
              height: 32,
              decoration: BoxDecoration(
                color: tint.withValues(alpha: 0.14),
                shape: BoxShape.circle,
              ),
              child: Icon(icon, size: 17, color: tint),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                text,
                style: TextStyle(
                  color: AppColors.textPrimary,
                  fontSize: 13.5,
                  height: 1.4,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// The page's one action. Breathes while it waits; turns green with a check
/// once Wi-Fi is off.
class _PrimaryAction extends StatelessWidget {
  final bool done;
  final String label;
  final String doneLabel;
  final VoidCallback onTap;

  const _PrimaryAction({
    required this.done,
    required this.label,
    required this.doneLabel,
    required this.onTap,
  });

  static final _radius = BorderRadius.circular(20);

  @override
  Widget build(BuildContext context) {
    final amber = AppColors.amber;
    final green = AppColors.green;
    final button = PressableScale(
      onTap: done ? null : onTap,
      borderRadius: _radius,
      child: AnimatedContainer(
        duration: AppMotion.card,
        curve: AppMotion.easeOut,
        height: 60,
        decoration: BoxDecoration(
          borderRadius: _radius,
          gradient: LinearGradient(
            begin: AlignmentDirectional.centerStart,
            end: AlignmentDirectional.centerEnd,
            colors: done
                ? [green, Color.lerp(green, Colors.teal, 0.35)!]
                : [amber, Color.lerp(amber, Colors.deepOrange, 0.35)!],
          ),
        ),
        child: AnimatedSwitcher(
          duration: AppMotion.card,
          switchInCurve: AppMotion.easeOut,
          switchOutCurve: AppMotion.leaving,
          transitionBuilder: (child, animation) => FadeTransition(
            opacity: animation,
            child: ScaleTransition(
              scale: Tween<double>(begin: 0.9, end: 1).animate(animation),
              child: child,
            ),
          ),
          child: Row(
            key: ValueKey(done),
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(
                done ? Icons.check_rounded : Icons.wifi_off_rounded,
                color: Colors.black,
                size: 24,
              ),
              const SizedBox(width: 10),
              Flexible(
                child: Text(
                  done ? doneLabel : label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: Colors.black,
                    fontSize: 16,
                    fontWeight: FontWeight.w800,
                    letterSpacing: 0.4,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
    return Semantics(
      button: true,
      enabled: !done,
      label: done ? doneLabel : label,
      excludeSemantics: true,
      child: PulseGlow(enabled: !done, borderRadius: _radius, child: button),
    );
  }
}
