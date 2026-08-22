import 'package:beat_transitions/beat_transitions.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:get_it/get_it.dart';
import 'package:go_router/go_router.dart';

import '../../../../core/l10n/extension.dart';
import '../../../../core/router/routes.dart';
import '../../../../core/sfx/sfx_event.dart';
import '../../../../core/sfx/sfx_service.dart';
import '../../../../core/theme/app_colors.dart';
import '../../../../core/theme/theme_service.dart';
import '../../../preflight/domain/service/pinned_plan.dart';
import '../../../preflight/presentation/page/preflight_page.dart';
import '../../../transfer/api/transfer_api.dart';
import '../manager/onboarding_cubit.dart';
import '../widget/callsign_step.dart';
import '../widget/horizon_scene.dart';
import '../widget/hud.dart';
import '../widget/onboarding_palette.dart';
import '../widget/ready_step.dart';
import '../widget/transport_step.dart';
import '../widget/tune_step.dart';
import '../widget/welcome_step.dart';
import '../widget/wind_background.dart';

/// First-run onboarding: one continuous scene, five beats.
///
/// Nothing pages or swipes — a travelling [HorizonScene] (parallax ridges, a
/// day/night sky, streaming ground) and a field of [WindBackground] streaks
/// persist while the beat content is handed over by a [HandoverTransition]
/// (old beat winds up and is thrown off the end, the stage sits empty in the
/// wind, the new one is brought in from the start under a reticle) and the
/// single CTA morphs its label, so the journey reads as one canvas rearranging
/// itself as you travel toward being on air:
///
///   tune in (language + theme, applied live — flips the sky day↔night) →
///   welcome (what this is) → callsign (who you are) → transport (how you
///   connect) → launch (key up on air).
///
/// Progress is gamified by a filling signal-strength meter in the header. The
/// final beat drives straight into the product: JOIN CHANNEL lands the user in
/// their transport's join flow (with Landing beneath it for back), while a
/// quieter link lets them explore the lobby first.
///
/// Choices stay in [OnboardingCubit] until the final CTA persists them all
/// at once; skipping marks onboarding done and touches nothing else. With
/// [replay] (Settings → Startup) the flow pops back instead of entering
/// the app.
class OnboardingPage extends StatefulWidget {
  const OnboardingPage._({required this.replay});

  final bool replay;

  /// [initialStep]/[initialName] deep-link a beat (and a callsign on the
  /// radio screen) for the preview harness; the real app always starts at the
  /// welcome beat with an empty handle.
  static Widget buildPage({
    bool replay = false,
    int initialStep = 0,
    String? initialName,
  }) => BlocProvider<OnboardingCubit>(
    create: (_) {
      final cubit = GetIt.instance<OnboardingCubit>()..jumpTo(initialStep);
      if (initialName != null && initialName.isNotEmpty) {
        cubit.setName(initialName);
      }
      return cubit;
    },
    child: OnboardingPage._(replay: replay),
  );

  @override
  State<OnboardingPage> createState() => _OnboardingPageState();
}

class _OnboardingPageState extends State<OnboardingPage>
    with TickerProviderStateMixin {
  /// Drives the between-beat transition — the [HandoverTransition] rides this
  /// clock: the outgoing panel winds up and is thrown off the end of the
  /// screen, the stage sits empty for a moment while the wind tears through
  /// it, and the next beat is brought in from the start under a reticle that
  /// snaps onto it. Long on purpose — the journey should feel like it is
  /// carrying you somewhere, not racing you through a form.
  late final AnimationController _stepT = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1100),
  );

  /// One-shot scene entrance for the persistent chrome (header, emblem,
  /// CTA); beats themselves ride [_stepT].
  late final AnimationController _intro = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 900),
  );

  /// Shared ambient clocks: breathing glow (selected HUD frames, transmit key
  /// border), a slow drift loop (parallax sway, celestial glow, VOX waveform),
  /// and the periodic gloss glint on the transmit key.
  late final AnimationController _pulse = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 2000),
  )..repeat(reverse: true);
  late final AnimationController _ambient = AnimationController(
    vsync: this,
    duration: const Duration(seconds: 12),
  )..repeat();
  late final AnimationController _shimmer = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 3200),
  )..repeat();

  /// Continuous travel clock: streams the horizon's foreground ground dashes
  /// so the whole scene always reads as moving toward being on air.
  late final AnimationController _scroll = AnimationController(
    vsync: this,
    duration: const Duration(seconds: 4),
  )..repeat();

  /// Time of day for the [HorizonScene]: 0 = day, 1 = night. Animated toward
  /// the tune beat's theme choice so picking Day/Night plays a real sunrise /
  /// sunset. Seeded in [initState] from the current preference so the scene
  /// opens at the right hour.
  late final AnimationController _dayNight = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1500),
  );

  /// One broadcast pulse per beat change (plus one on entrance): sends a gust
  /// through the [WindBackground] so the whole scene keys up as a single
  /// gesture.
  late final AnimationController _wave = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1300),
  );

  late final Animation<double> _breath = CurvedAnimation(
    parent: _pulse,
    curve: Curves.easeInOut,
  );

  /// Per-child stagger for the beat's contents. Used **only for the journey's
  /// very first beat**: during a handover the beats are held assembled so each
  /// one is a static raster the compositor can transform for free, which is
  /// what buys the transition its headroom on a weak GPU. The arrival's
  /// choreography (bounce, reticle lock) carries the moment instead.
  late final Animation<double> _reveal = CurvedAnimation(
    parent: _stepT,
    curve: const Interval(0.15, 0.75),
  );

  int _shown = 0;
  int? _leaving;
  int _dir = 1;
  bool _finishing = false;

  @override
  void initState() {
    super.initState();
    // The cubit may start past beat 0 (preview deep-link); the transition
    // listener only fires on *changes*, so seed the staged beat from it.
    final state = context.read<OnboardingCubit>().state;
    _shown = state.step;
    _dayNight.value = state.themePref == AppThemeMode.light ? 0.0 : 1.0;
    _intro.forward();
    _stepT.forward();
    _wave.forward(from: 0);
  }

  /// Plays the sunrise/sunset toward the chosen theme.
  void _syncDayNight(AppThemeMode mode) {
    _dayNight.animateTo(
      mode == AppThemeMode.light ? 0.0 : 1.0,
      curve: Curves.easeInOutCubic,
    );
  }

  @override
  void dispose() {
    _stepT.dispose();
    _intro.dispose();
    _pulse.dispose();
    _ambient.dispose();
    _shimmer.dispose();
    _scroll.dispose();
    _dayNight.dispose();
    _wave.dispose();
    super.dispose();
  }

  void _onStepChanged(int newStep) {
    FocusManager.instance.primaryFocus?.unfocus();
    final advancing = newStep > _shown;
    if (advancing) Sfx.play(SfxEvent.toggle);
    _wave.forward(from: 0);
    setState(() {
      _leaving = _shown;
      _dir = advancing ? 1 : -1;
      _shown = newStep;
    });
    _stepT.forward(from: 0).whenComplete(() {
      if (!mounted) return;
      setState(() => _leaving = null);
      // The READY stamp rides the tail of this transition — land it with
      // an audible thunk and a firmer haptic than a plain step.
      if (advancing && _shown == OnboardingCubit.launchStep) {
        Sfx.play(SfxEvent.peerJoin);
        HapticFeedback.mediumImpact();
      }
    });
  }

  /// Primary hand-off: persist everything, mark the quick-access flag, and
  /// drop the user into their transport's setup flow, with Landing stacked
  /// beneath so back behaves normally.
  ///
  /// **Automatic stops on Landing, deliberately.** With no pinned transport
  /// there is no flow to push: the advisor needs an intent to resolve one, and
  /// the only thing that supplies an intent is the user tapping START or JOIN.
  /// Guessing here would put a first-run user inside a hotspot or a Bluetooth
  /// scan they never asked for. Landing is not a detour out of the journey —
  /// P2 §1 made it the room screen, so the flow still ends on two lit buttons
  /// with the primary one breathing.
  Future<void> _launch(OnboardingCubit cubit) async {
    if (_finishing) return;
    _finishing = true;
    HapticFeedback.mediumImpact();
    await cubit.launch();
    if (!mounted) return;
    final mode = cubit.state.mode;
    // Preflight (#33): only meaningful once a transport is actually about to
    // be walked — "automatic" (mode == null) stops on Landing with nothing
    // committed yet, same as before this existed.
    if (mode != null) {
      final plan = await pinnedPlanFor(mode);
      if (!mounted) return;
      final proceed = await showPreflightPage(context, plan: plan);
      if (!proceed || !mounted) return;
    }
    context.go(AppRoutes.landingPath);
    switch (cubit.state.mode) {
      case null:
        break;
      case TransferMode.bluetooth:
        context.pushNamed(AppRoutes.bluetoothConnectName);
      case TransferMode.guest:
        context.pushNamed(AppRoutes.guestLinkName);
      case TransferMode.wifi:
        // Direct Wi-Fi has nothing to set up — land straight in the channel;
        // the Wi-Fi/Hotspot setup page is only for the explicit hotspot flow.
        context.pushNamed(AppRoutes.walkieName);
      case TransferMode.hotspot:
        context.pushNamed(
          AppRoutes.wifiHotspotName,
          queryParameters: const {'mode': 'hotspot'},
        );
    }
  }

  /// Secondary path on the launch beat: same persistence, but lands on the
  /// lobby to look around instead of joining right away.
  Future<void> _explore(OnboardingCubit cubit) async {
    if (_finishing) return;
    _finishing = true;
    await cubit.finish();
    if (!mounted) return;
    context.go(AppRoutes.landingPath);
  }

  /// Replay (from Settings) ends by popping back, keeping any edits.
  Future<void> _finishReplay(OnboardingCubit cubit) async {
    if (_finishing) return;
    _finishing = true;
    HapticFeedback.mediumImpact();
    await cubit.finish();
    if (!mounted) return;
    context.pop();
  }

  Future<void> _skip(OnboardingCubit cubit) async {
    if (_finishing) return;
    _finishing = true;
    await cubit.skip();
    if (!mounted) return;
    if (widget.replay) {
      context.pop();
    } else {
      context.go(AppRoutes.landingPath);
    }
  }

  @override
  Widget build(BuildContext context) {
    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: AppColors.systemOverlayStyle,
      child: BlocConsumer<OnboardingCubit, OnboardingState>(
        listenWhen: (p, c) => p.step != c.step || p.themePref != c.themePref,
        listener: (_, state) {
          if (state.step != _shown) _onStepChanged(state.step);
          _syncDayNight(state.themePref);
        },
        builder: (context, state) {
          final cubit = context.read<OnboardingCubit>();
          return PopScope(
            // System back walks the journey backwards; only a back press on
            // the first beat leaves the page (exits on first run, returns
            // to Settings in replay).
            canPop: state.step == 0,
            onPopInvokedWithResult: (didPop, _) {
              if (!didPop) cubit.back();
            },
            child: Scaffold(
              backgroundColor: AppColors.background,
              // The callsign field lives in the top panel; let the keyboard
              // overlay the lower scene/radio/key rather than squeezing the
              // fixed-height column into an overflow.
              resizeToAvoidBottomInset: false,
              body: Stack(
                children: [
                  Positioned.fill(
                    child: HorizonScene(
                      drift: _ambient,
                      scroll: _scroll,
                      dayNight: _dayNight,
                    ),
                  ),
                  Positioned.fill(
                    // Ambient wind streaming past on the air — each beat change
                    // sends a gust through it (via [_wave]) so the scene keys up
                    // as one gesture.
                    child: WindBackground(wave: _wave),
                  ),
                  SafeArea(
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 24),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          _buildHeader(context, cubit, state),
                          Expanded(child: _buildBeats(state)),
                          _buildCta(context, cubit, state),
                          _buildExplore(context, cubit, state),
                          const SizedBox(height: 4),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  // ── Header: back · progress · skip ─────────────────────────────────────────

  Widget _buildHeader(
    BuildContext context,
    OnboardingCubit cubit,
    OnboardingState state,
  ) {
    final s = context.getString;
    final isLast = state.step == OnboardingCubit.stepCount - 1;
    return FadeTransition(
      opacity: CurvedAnimation(parent: _intro, curve: Curves.easeOut),
      child: SizedBox(
        height: 56,
        child: Stack(
          alignment: Alignment.center,
          children: [
            Center(
              child: SignalMeter(
                step: state.step,
                stepCount: OnboardingCubit.stepCount,
              ),
            ),
            Align(
              alignment: AlignmentDirectional.centerStart,
              child: _HeaderButton(
                visible: state.step > 0,
                onTap: cubit.back,
                child: Icon(
                  Icons.arrow_back_rounded,
                  color: Onb.textDim,
                  size: 20,
                ),
              ),
            ),
            Align(
              alignment: AlignmentDirectional.centerEnd,
              child: _HeaderButton(
                visible: !isLast,
                onTap: () => _skip(cubit),
                child: Text(
                  s.onboarding_skip,
                  style: const TextStyle(
                    color: Onb.textDim,
                    fontSize: 11,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 1.5,
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  // ── Beat content: the journey's centre stage ──────────────────────────────

  Widget _buildBeats(OnboardingState state) {
    // Deliberately *not* wrapped in an AnimatedBuilder: the beats are built
    // here, on bloc rebuilds only, and [BeatTransitionView] animates them by
    // repainting cached rasters. Rebuilding both step subtrees 60 times a
    // second — which is what the old sweep did — was the single biggest cost
    // of the journey on a low-end phone.
    // Both beats are held fully assembled during a handover, so each is a
    // static picture the compositor can transform and fade without re-recording
    // it — the difference between "two panels move" and "two whole HUD subtrees
    // repaint" 60 times a second. Only the journey's opening beat, which has no
    // predecessor to hand over from, plays the per-child stagger.
    final firstBeat = _leaving == null;
    final stage = BeatTransitionView(
      progress: _stepT,
      direction: _dir,
      leaving: firstBeat
          ? null
          : _buildBeat(_leaving!, kAlwaysCompleteAnimation),
      incoming: _buildBeat(
        _shown,
        firstBeat ? _reveal : kAlwaysCompleteAnimation,
      ),
      transition: const HandoverTransition(accent: Onb.amber),
    );
    // With the radio band gone the beats own the whole middle: sit them a
    // touch below centre so the composition breathes, while still allowing
    // a scroll when a small screen (or the keyboard) squeezes the column.
    return LayoutBuilder(
      builder: (context, constraints) => SingleChildScrollView(
        physics: const ClampingScrollPhysics(),
        child: ConstrainedBox(
          constraints: BoxConstraints(minHeight: constraints.maxHeight),
          child: Align(
            alignment: const Alignment(0, 0.16),
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 8),
              child: stage,
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildBeat(int step, Animation<double> reveal) => switch (step) {
    OnboardingCubit.tuneStep => TuneStep(reveal: reveal),
    OnboardingCubit.welcomeStep => WelcomeStep(
      reveal: reveal,
      ambient: _ambient,
    ),
    OnboardingCubit.callsignStep => CallsignStep(
      reveal: reveal,
      onSubmit: () => context.read<OnboardingCubit>().next(),
    ),
    OnboardingCubit.transportStep => TransportStep(reveal: reveal),
    _ => ReadyStep(reveal: reveal, shimmer: _shimmer),
  };

  // ── Persistent transmit key: the diegetic CTA whose label morphs per beat ──

  Widget _buildCta(
    BuildContext context,
    OnboardingCubit cubit,
    OnboardingState state,
  ) {
    final s = context.getString;
    final isLast = state.step == OnboardingCubit.launchStep;
    final enabled = state.canContinue && !_finishing;
    final label = switch (state.step) {
      OnboardingCubit.tuneStep => s.onboarding_begin,
      OnboardingCubit.launchStep =>
        widget.replay ? s.onboarding_finish : s.join_channel,
      _ => s.onboarding_continue,
    };
    // Pulse only on the bookend beats — mid-journey the key stays calm so the
    // beat content owns the motion.
    final pulsing =
        enabled && (state.step == OnboardingCubit.tuneStep || isLast);

    void onTap() {
      HapticFeedback.selectionClick();
      if (!isLast) {
        cubit.next();
      } else if (widget.replay) {
        _finishReplay(cubit);
      } else {
        _launch(cubit);
      }
    }

    return FadeTransition(
      opacity: CurvedAnimation(parent: _intro, curve: Curves.easeOut),
      // The key repaints every frame *while pulsing*; the boundary keeps that
      // off the layer shared with the rest of the column.
      child: RepaintBoundary(
        // Mid-journey the key is completely static — so don't hang it off the
        // ambient clocks at all. Subscribing anyway meant the CTA re-recorded
        // its frame, gradient and glow 60 times a second on every beat, to
        // paint a pixel-identical result.
        child: pulsing
            ? AnimatedBuilder(
                animation: Listenable.merge([_breath, _shimmer]),
                builder: (_, _) => HudActionKey(
                  key: ValueKey('$label-$enabled'),
                  label: label,
                  enabled: enabled,
                  pulsing: true,
                  go: isLast,
                  glow: _breath.value,
                  gloss: _shimmer.value,
                  onTap: onTap,
                ),
              )
            : HudActionKey(
                key: ValueKey('$label-$enabled'),
                label: label,
                enabled: enabled,
                go: isLast,
                onTap: onTap,
              ),
      ),
    );
  }

  // ── Quiet exit: look around the lobby instead of joining right away ────────

  /// Fixed-height slot under the key so it never shifts; the link itself only
  /// exists on the launch beat of a real first run.
  Widget _buildExplore(
    BuildContext context,
    OnboardingCubit cubit,
    OnboardingState state,
  ) {
    final visible = state.step == OnboardingCubit.launchStep && !widget.replay;
    return SizedBox(
      height: 38,
      child: Center(
        child: AnimatedOpacity(
          duration: const Duration(milliseconds: 300),
          opacity: visible ? 1 : 0,
          child: IgnorePointer(
            ignoring: !visible,
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: () => _explore(cubit),
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 8,
                ),
                child: Text(
                  '‹ ${context.getString.onboarding_explore} ›'.toUpperCase(),
                  style: TextStyle(
                    color: Onb.textDim,
                    fontSize: 11,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 1.5,
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

/// Small fading header affordance (back / skip) that ignores taps while
/// hidden.
class _HeaderButton extends StatelessWidget {
  final bool visible;
  final VoidCallback onTap;
  final Widget child;

  const _HeaderButton({
    required this.visible,
    required this.onTap,
    required this.child,
  });

  @override
  Widget build(BuildContext context) {
    return AnimatedOpacity(
      duration: const Duration(milliseconds: 300),
      opacity: visible ? 1 : 0,
      child: IgnorePointer(
        ignoring: !visible,
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: onTap,
          child: Padding(padding: const EdgeInsets.all(12), child: child),
        ),
      ),
    );
  }
}
