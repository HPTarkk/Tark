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
import '../../../../core/widget/mesh_background.dart';
import '../../../transfer/api/transfer_api.dart';
import '../manager/onboarding_cubit.dart';
import '../widget/assembling_radio.dart';
import '../widget/beat_transitions.dart';
import '../widget/callsign_step.dart';
import '../widget/horizon_scene.dart';
import '../widget/hud.dart';
import '../widget/onboarding_palette.dart';
import '../widget/ready_step.dart';
import '../widget/transport_step.dart';
import '../widget/tune_step.dart';
import '../widget/welcome_step.dart';

/// First-run onboarding: one continuous scene, five beats.
///
/// Nothing pages or swipes — a travelling [HorizonScene] (parallax ridges,
/// a day/night sky, streaming ground) and a handheld radio that *assembles
/// itself* persist while beat content cross-slides above them and the single
/// CTA morphs its label, so the journey reads as one canvas rearranging
/// itself while the unit is built up piece by piece:
///
///   tune in (language + theme, applied live — flips the sky day↔night;
///   chassis drops in) → welcome (what this is; antenna telescopes up) →
///   callsign (who you are; the screen lights with your handle) → transport
///   (how you connect; the link module clips on) → launch (PTT + LED go live
///   and the unit keys up on air).
///
/// Progress is gamified twice over: a filling signal-strength meter in the
/// header and the radio earning a component each beat. The final beat drives
/// straight into the product: JOIN CHANNEL lands the user in their transport's
/// join flow (with Landing beneath it for back), while a quieter link lets
/// them explore the lobby first.
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
  /// Drives the between-beat transition. Each boundary gets its own signature
  /// motion (see [buildBeatTransition]) but they all ride this one clock; the
  /// duration is generous so the choreography reads as cinematic rather than a
  /// quick shuffle, and the incoming beat's children stagger off it too.
  late final AnimationController _stepT = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 650),
  );

  /// One-shot scene entrance for the persistent chrome (header, emblem,
  /// CTA); beats themselves ride [_stepT].
  late final AnimationController _intro = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 900),
  );

  /// Shared ambient clocks: breathing glow (radio live parts, selected HUD
  /// frames, transmit key border), a slow drift loop (parallax sway, celestial
  /// glow, VOX waveform), and the periodic gloss glint (transmit key + operator
  /// panel).
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

  /// One broadcast pulse per beat change (plus one on entrance): drives the
  /// mesh wavefront and the emblem's kick/burst together so the whole scene
  /// keys up as a single gesture.
  late final AnimationController _wave = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1300),
  );

  late final Animation<double> _breath = CurvedAnimation(
    parent: _pulse,
    curve: Curves.easeInOut,
  );

  /// Incoming beat's per-child stagger. It finishes well before [_stepT] does
  /// so the panel's contents are assembled while the boundary transition
  /// (flip/glide/warp/rise) is still settling the whole block into place —
  /// the details land first, then the panel comes to rest.
  late final Animation<double> _reveal = CurvedAnimation(
    parent: _stepT,
    curve: const Interval(0.15, 0.85),
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
  /// drop the user into their transport's join flow — the same destination
  /// Landing's Join button routes to — with Landing stacked beneath so back
  /// behaves normally.
  Future<void> _launch(OnboardingCubit cubit) async {
    if (_finishing) return;
    _finishing = true;
    HapticFeedback.mediumImpact();
    await cubit.launch();
    if (!mounted) return;
    context.go(AppRoutes.landingPath);
    switch (cubit.state.mode) {
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
                    child: MeshBackground(
                      wave: _wave,
                      // Epicenter ≈ where the radio's antenna sits, so mesh
                      // pulses read as the unit keying up the whole network.
                      waveOrigin: const Offset(0.5, 0.72),
                    ),
                  ),
                  SafeArea(
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 24),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          _buildHeader(context, cubit, state),
                          Expanded(child: _buildBeats(state)),
                          _buildRadio(state),
                          const SizedBox(height: 10),
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

  // ── Radio band: the unit that assembles itself as the journey advances ─────

  /// The gamified hero — a handheld radio that gains a component per beat and
  /// keys up on the launch beat. It sits low, on the horizon's ground line, so
  /// it reads as standing on the road the scene is travelling.
  Widget _buildRadio(OnboardingState state) {
    final introT = CurvedAnimation(parent: _intro, curve: Curves.easeOutCubic);
    return AnimatedBuilder(
      // Entrance: the unit rises into the scene while fading in.
      animation: introT,
      builder: (_, child) => Opacity(
        opacity: introT.value,
        child: Transform.translate(
          offset: Offset(0, 24 * (1 - introT.value)),
          child: child,
        ),
      ),
      child: SizedBox(
        height: 218,
        child: Center(
          // The radio repaints every frame on the ambient clocks; the boundary
          // keeps that off the layer shared with the static beat content.
          child: RepaintBoundary(
            child: AnimatedBuilder(
              animation: Listenable.merge([_breath, _shimmer, _wave]),
              builder: (_, _) => AssemblingRadio(
                step: state.step,
                glow: _breath.value,
                scan: _shimmer.value,
                kick: _wave.value,
                callsign: state.name,
                mode: state.mode,
              ),
            ),
          ),
        ),
      ),
    );
  }

  // ── Beat content: one distinct transition per boundary ─────────────────────

  Widget _buildBeats(OnboardingState state) {
    final width = MediaQuery.sizeOf(context).width;
    return AnimatedBuilder(
      animation: _stepT,
      builder: (context, _) {
        final raw = _stepT.value;
        // The boundary being crossed = the lower of the two steps, so each
        // gap keeps its signature motion whichever way it's traversed.
        final gap = _leaving == null
            ? (_shown - 1).clamp(0, 3)
            : (_leaving! < _shown ? _leaving! : _shown);
        return SingleChildScrollView(
          physics: const ClampingScrollPhysics(),
          padding: const EdgeInsets.only(top: 4, bottom: 8),
          child: Stack(
            // Let the 3D flip / horizontal glide paint past the Stack's own
            // bounds; the surrounding scroll viewport still clips to the band.
            clipBehavior: Clip.none,
            children: [
              if (_leaving != null)
                IgnorePointer(
                  child: buildBeatTransition(
                    gap: gap,
                    dir: _dir,
                    leaving: true,
                    t: raw,
                    width: width,
                    child: _buildBeat(_leaving!),
                  ),
                ),
              buildBeatTransition(
                gap: gap,
                dir: _dir,
                leaving: false,
                t: raw,
                width: width,
                child: _buildBeat(_shown),
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _buildBeat(int step) => switch (step) {
    OnboardingCubit.tuneStep => TuneStep(reveal: _reveal),
    OnboardingCubit.welcomeStep => WelcomeStep(
      reveal: _reveal,
      ambient: _ambient,
    ),
    OnboardingCubit.callsignStep => CallsignStep(
      reveal: _reveal,
      onSubmit: () => context.read<OnboardingCubit>().next(),
    ),
    OnboardingCubit.transportStep => TransportStep(reveal: _reveal),
    _ => ReadyStep(reveal: _reveal, shimmer: _shimmer),
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
      // The key repaints every frame on the glow/gloss clocks; the boundary
      // keeps that off the layer shared with the rest of the column.
      child: RepaintBoundary(
        child: AnimatedBuilder(
          animation: Listenable.merge([_breath, _shimmer]),
          builder: (_, _) => HudActionKey(
            key: ValueKey('$label-$enabled'),
            label: label,
            enabled: enabled,
            pulsing: pulsing,
            go: isLast,
            glow: _breath.value,
            gloss: _shimmer.value,
            onTap: onTap,
          ),
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
