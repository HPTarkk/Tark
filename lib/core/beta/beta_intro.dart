import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:get_it/get_it.dart';

import '../diagnostics/screen_log.dart';
import '../l10n/app_localizations.dart';
import '../l10n/extension.dart';
import '../motion/app_motion.dart';
import '../settings/settings_repository.dart';
import '../theme/app_colors.dart';
import '../widget/sheet_shell.dart';
import 'beta_badge.dart';
import 'beta_feature.dart';
import 'beta_style.dart';

/// How the person left the beta intro.
enum BetaIntroChoice {
  /// "Got it" — or any plain dismissal (scrim, swipe, system back): they
  /// read it and stayed, which is consent enough not to ask again.
  proceed,

  /// "Not now" — they would rather not try a beta today. The screen behind
  /// the sheet is left, and the intro will be offered again next time.
  back,
}

/// The friendly "this is still in beta" sheet for [feature].
///
/// Tone is the whole design brief: honest that it may stumble, warm about
/// trying it, and always naming the steadier path — so the person feels
/// invited into something new rather than warned off something broken.
///
/// [informational] is the re-read from a notice's "What's that?": there is no
/// decision to make then, so the sheet offers only "Got it".
Future<BetaIntroChoice> showBetaIntroSheet(
  BuildContext context,
  BetaFeature feature, {
  bool informational = false,
}) async {
  HapticFeedback.lightImpact();
  final choice = await showModalBottomSheet<BetaIntroChoice>(
    context: context,
    routeSettings: RouteSettings(name: 'BetaIntroSheet:${feature.key}'),
    backgroundColor: Colors.transparent,
    isScrollControlled: true,
    barrierColor: Colors.black.withValues(alpha: 0.6),
    builder: (_) =>
        BetaIntroSheet(feature: feature, informational: informational),
  );
  return choice ?? BetaIntroChoice.proceed;
}

/// Shows [feature]'s beta intro the first time [child] is entered on this
/// install, once its route has finished arriving.
///
/// Wrap the page that *is* the beta feature — not the rows that lead to it —
/// so the intro meets the person at the moment they actually step in, and
/// every way of arriving (a picker, quick access, the home-screen widget) is
/// covered by one gate. Remembered per feature through
/// [SettingsRepository.getBetaIntroSeen].
class BetaIntroGate extends StatefulWidget {
  const BetaIntroGate({
    required this.feature,
    required this.child,
    this.repository,
    super.key,
  });

  final BetaFeature feature;
  final Widget child;

  /// Defaults to the registered [SettingsRepository]. With none registered
  /// (the browser guest build, most widget tests) the gate is transparent.
  final SettingsRepository? repository;

  @override
  State<BetaIntroGate> createState() => _BetaIntroGateState();
}

class _BetaIntroGateState extends State<BetaIntroGate> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback(
      (_) => unawaited(_maybeShow()),
    );
  }

  SettingsRepository? get _repository {
    if (widget.repository != null) return widget.repository;
    final getIt = GetIt.instance;
    return getIt.isRegistered<SettingsRepository>()
        ? getIt<SettingsRepository>()
        : null;
  }

  Future<void> _maybeShow() async {
    final repository = _repository;
    if (repository == null) return;
    final bool seen;
    try {
      seen = await repository.getBetaIntroSeen(widget.feature);
    } catch (_) {
      return;
    }
    if (seen || !mounted) return;
    await _routeSettled();
    if (!mounted) return;
    // Something else was pushed on top while we waited (a scanner, a
    // permission prompt): never stack the intro over it.
    final route = ModalRoute.of(context);
    if (route != null && !route.isCurrent) return;
    ScreenLog.tap('Beta intro ${widget.feature.key}');
    final choice = await showBetaIntroSheet(context, widget.feature);
    if (!mounted) return;
    if (choice == BetaIntroChoice.back) {
      // Through the page's own back handling (its PopScope), so whatever it
      // tears down on leaving is torn down exactly as for a back gesture.
      await Navigator.of(context).maybePop();
      return;
    }
    try {
      await repository.setBetaIntroSeen(widget.feature, true);
    } catch (_) {
      // Worst case the friendly sheet is offered once more. Never a blocker.
    }
  }

  /// Waits for the page's own push transition, then one beat more: a sheet
  /// rising while the page is still sliding in reads as one muddled motion
  /// instead of two clear ones.
  Future<void> _routeSettled() async {
    final animation = ModalRoute.of(context)?.animation;
    if (animation != null && animation.status != AnimationStatus.completed) {
      final done = Completer<void>();
      void listener(AnimationStatus status) {
        if (status == AnimationStatus.completed ||
            status == AnimationStatus.dismissed) {
          if (!done.isCompleted) done.complete();
        }
      }

      animation.addStatusListener(listener);
      await done.future.timeout(const Duration(seconds: 2), onTimeout: () {});
      animation.removeStatusListener(listener);
    }
    await Future<void>.delayed(AppMotion.card);
  }

  @override
  Widget build(BuildContext context) => widget.child;
}

/// The intro sheet's content. Public so it can be pumped on its own in tests
/// and screenshots; open it with [showBetaIntroSheet].
class BetaIntroSheet extends StatelessWidget {
  const BetaIntroSheet({
    required this.feature,
    this.informational = false,
    super.key,
  });

  final BetaFeature feature;
  final bool informational;

  @override
  Widget build(BuildContext context) {
    final s = context.getString;
    final copy = _BetaCopy.of(feature, s);
    return SheetShell(
      topFraction: 0.16,
      borderColor: BetaStyle.violet.withValues(alpha: 0.35),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(22, 6, 22, 18),
        child: StaggeredEntrance(
          builder: (context, children) => Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: children,
          ),
          children: [
            const Center(child: _LabEmblem()),
            const SizedBox(height: 14),
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                const BetaPill(showIcon: false),
                const SizedBox(width: 8),
                Flexible(
                  child: Text(
                    feature.label(s),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: BetaStyle.ink,
                      fontSize: 12,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Text(
              s.beta_intro_title,
              textAlign: TextAlign.center,
              style: TextStyle(
                color: AppColors.textPrimary,
                fontSize: 21,
                fontWeight: FontWeight.w800,
                height: 1.3,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              copy.body,
              textAlign: TextAlign.center,
              style: TextStyle(
                color: AppColors.textSecondary,
                fontSize: 13.5,
                height: 1.6,
              ),
            ),
            const SizedBox(height: 16),
            _Point(icon: Icons.check_circle_rounded, text: copy.works),
            const SizedBox(height: 10),
            _Point(icon: Icons.bug_report_rounded, text: copy.bugs),
            const SizedBox(height: 10),
            _Point(icon: Icons.route_rounded, text: copy.steadier),
            const SizedBox(height: 22),
            _BetaButton(
              key: const Key('beta-intro-proceed'),
              label: s.beta_intro_cta,
              onTap: () => Navigator.pop(context, BetaIntroChoice.proceed),
            ),
            if (!informational) ...[
              const SizedBox(height: 6),
              TextButton(
                key: const Key('beta-intro-back'),
                onPressed: () => Navigator.pop(context, BetaIntroChoice.back),
                style: TextButton.styleFrom(
                  foregroundColor: AppColors.textSecondary,
                  padding: const EdgeInsets.symmetric(vertical: 12),
                ),
                child: Text(
                  s.beta_intro_back,
                  style: const TextStyle(fontWeight: FontWeight.w700),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// A slim inline note that sits on a beta screen for as long as it is open:
/// the pill, one sentence, and "What's that?" to re-read the intro.
///
/// Calm by design — no icon of alarm, no colour of warning. It is there so
/// nobody mistakes the screen for the finished road, not to make them doubt
/// pressing anything on it.
class BetaNotice extends StatelessWidget {
  const BetaNotice({required this.feature, required this.message, super.key});

  final BetaFeature feature;
  final String message;

  @override
  Widget build(BuildContext context) {
    final s = context.getString;
    return Container(
      padding: const EdgeInsetsDirectional.fromSTEB(12, 10, 6, 10),
      decoration: BoxDecoration(
        gradient: BetaStyle.wash(alpha: 0.07),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: BetaStyle.violet.withValues(alpha: 0.30)),
      ),
      child: Row(
        children: [
          const BetaPill(),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              message,
              style: TextStyle(
                color: AppColors.textSecondary,
                fontSize: 11.5,
                height: 1.45,
              ),
            ),
          ),
          TextButton(
            key: const Key('beta-notice-more'),
            onPressed: () {
              ScreenLog.tap('Beta notice more ${feature.key}');
              unawaited(
                showBetaIntroSheet(context, feature, informational: true),
              );
            },
            style: TextButton.styleFrom(
              foregroundColor: BetaStyle.ink,
              padding: const EdgeInsets.symmetric(horizontal: 8),
              minimumSize: const Size(0, 36),
              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
            ),
            child: Text(
              s.beta_notice_more,
              style: const TextStyle(
                fontSize: 11.5,
                fontWeight: FontWeight.w800,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// ── Pieces ──────────────────────────────────────────────────────────────────

/// Per-feature wording. The structure — it works, it may stumble, here is the
/// steadier road — is the same for every beta; only the specifics change.
class _BetaCopy {
  const _BetaCopy({
    required this.body,
    required this.works,
    required this.bugs,
    required this.steadier,
  });

  final String body;
  final String works;
  final String bugs;
  final String steadier;

  static _BetaCopy of(BetaFeature feature, AppLocalizations s) =>
      switch (feature) {
        BetaFeature.guestConnection => _BetaCopy(
          body: s.beta_guest_intro_body,
          works: s.beta_guest_intro_works,
          bugs: s.beta_guest_intro_bugs,
          steadier: s.beta_guest_intro_steadier,
        ),
        BetaFeature.homeWidget => _BetaCopy(
          body: s.beta_widget_intro_body,
          works: s.beta_widget_intro_works,
          bugs: s.beta_widget_intro_bugs,
          steadier: s.beta_widget_intro_steadier,
        ),
      };
}

class _Point extends StatelessWidget {
  const _Point({required this.icon, required this.text});

  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) => Row(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Container(
        width: 26,
        height: 26,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          gradient: BetaStyle.wash(alpha: 0.16),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Icon(icon, size: 15, color: BetaStyle.ink),
      ),
      const SizedBox(width: 10),
      Expanded(
        child: Padding(
          padding: const EdgeInsets.only(top: 3),
          child: Text(
            text,
            style: TextStyle(
              color: AppColors.textPrimary.withValues(alpha: 0.88),
              fontSize: 13,
              height: 1.5,
            ),
          ),
        ),
      ),
    ],
  );
}

/// The sheet's one action, in the beta gradient: a hairline of the full
/// gradient around a washed fill, so it is unmistakably *this* family's
/// button and never confused with the amber primary on the page behind.
class _BetaButton extends StatelessWidget {
  const _BetaButton({required this.label, required this.onTap, super.key});

  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Semantics(
    button: true,
    label: label,
    excludeSemantics: true,
    child: PressableScale(
      onTap: onTap,
      borderRadius: BorderRadius.circular(14),
      child: DecoratedBox(
        decoration: BoxDecoration(
          gradient: BetaStyle.gradient(),
          borderRadius: BorderRadius.circular(14),
        ),
        child: Padding(
          padding: const EdgeInsets.all(1.5),
          child: DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                colors: [
                  Color.alphaBlend(
                    BetaStyle.teal.withValues(alpha: 0.10),
                    AppColors.surface,
                  ),
                  Color.alphaBlend(
                    BetaStyle.violet.withValues(alpha: 0.12),
                    AppColors.surface,
                  ),
                ],
              ),
              borderRadius: BorderRadius.circular(12.5),
            ),
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 13),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(Icons.science_rounded, size: 18, color: BetaStyle.ink),
                  const SizedBox(width: 8),
                  Flexible(
                    child: Text(
                      label,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: BetaStyle.ink,
                        fontSize: 14,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    ),
  );
}

/// The intro's hero: a flask in a slowly turning ring of lab glass, bubbles
/// rising out of it. One controller drives everything — the ring's turn and
/// the bubbles read the same cycle — and the ring is a single painted stroke
/// under a RepaintBoundary, so on the floor device this costs one small layer
/// per frame.
class _LabEmblem extends StatefulWidget {
  const _LabEmblem();

  @override
  State<_LabEmblem> createState() => _LabEmblemState();
}

class _LabEmblemState extends State<_LabEmblem>
    with SingleTickerProviderStateMixin {
  late final AnimationController _cycle = AnimationController(
    vsync: this,
    duration: BetaStyle.cycle,
  );

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _cycle.loopUnlessReduced(context, rest: 0.5);
  }

  @override
  void dispose() {
    _cycle.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    const size = 84.0;
    final reduced = AppMotion.reduced(context);
    return TweenAnimationBuilder<double>(
      tween: Tween(begin: 0, end: 1),
      duration: const Duration(milliseconds: 620),
      curve: Curves.easeOutBack,
      builder: (context, v, child) => Opacity(
        opacity: v.clamp(0.0, 1.0),
        child: reduced
            ? child
            : Transform.scale(scale: 0.6 + 0.4 * v, child: child),
      ),
      child: SizedBox.square(
        dimension: size,
        child: Stack(
          alignment: Alignment.center,
          children: [
            Container(
              width: size - 18,
              height: size - 18,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                gradient: RadialGradient(
                  colors: [
                    BetaStyle.violet.withValues(alpha: 0.22),
                    BetaStyle.teal.withValues(alpha: 0.05),
                  ],
                ),
              ),
            ),
            RepaintBoundary(
              child: CustomPaint(
                size: const Size.square(size),
                painter: _RingPainter(turn: _cycle),
              ),
            ),
            CustomPaint(
              foregroundPainter: BetaBubblePainter(
                progress: _cycle,
                color: BetaStyle.teal,
                count: 3,
              ),
              child: ShaderMask(
                blendMode: BlendMode.srcIn,
                shaderCallback: (rect) => LinearGradient(
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                  colors: [BetaStyle.teal, BetaStyle.violet],
                ).createShader(rect),
                child: const Icon(
                  Icons.science_rounded,
                  size: 36,
                  color: Colors.white,
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
  _RingPainter({required this.turn}) : super(repaint: turn);

  final Animation<double> turn;

  @override
  void paint(Canvas canvas, Size size) {
    final centre = size.center(Offset.zero);
    final radius = size.shortestSide / 2 - 3;
    final rect = Rect.fromCircle(center: centre, radius: radius);
    // Two-fold symmetric sweep, so turning half a revolution per cycle loops
    // without a seam.
    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.2
      ..strokeCap = StrokeCap.round
      ..shader = SweepGradient(
        transform: GradientRotation(turn.value * math.pi),
        colors: [
          BetaStyle.teal,
          BetaStyle.violet.withValues(alpha: 0.15),
          BetaStyle.teal,
          BetaStyle.violet.withValues(alpha: 0.15),
          BetaStyle.teal,
        ],
      ).createShader(rect);
    canvas.drawCircle(centre, radius, paint);
    // An orbiting spark riding the ring — the "something is running" cue.
    final angle = turn.value * math.pi * 2 - math.pi / 2;
    final spark = centre + Offset(math.cos(angle), math.sin(angle)) * radius;
    canvas
      ..drawCircle(
        spark,
        4.5,
        Paint()..color = BetaStyle.teal.withValues(alpha: 0.25),
      )
      ..drawCircle(spark, 2.2, Paint()..color = BetaStyle.teal);
  }

  @override
  bool shouldRepaint(_RingPainter old) => old.turn != turn;
}
