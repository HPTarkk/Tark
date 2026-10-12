import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/physics.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:get_it/get_it.dart';
import 'package:go_router/go_router.dart';

import '../../../../core/diagnostics/screen_log.dart';
import '../../../../core/l10n/extension.dart';
import '../../../../core/motion/app_motion.dart';
import '../../../../core/motion/continuity_route.dart';
import '../../../../core/router/routes.dart';
import '../../../../core/sfx/sfx_event.dart';
import '../../../../core/sfx/sfx_service.dart';
import '../../../../core/theme/app_colors.dart';
import '../../../../core/theme/theme_service.dart';
import '../../../../core/widget/mesh_background.dart';
import '../../../landing/api/landing_api.dart';
import '../manager/onboarding_cubit.dart';
import '../widget/onboarding_controls.dart';
import '../widget/onboarding_movements.dart';
import '../widget/onboarding_stage.dart';
import '../widget/step_swap.dart';

/// First run, as one continuous scene in three movements:
///
///   **hello** (what this is; language and look, applied live) →
///   **you** (callsign and face, on one screen) →
///   **your room** (create one, scan into one, or later).
///
/// It stands on the product's own ground — the same drifting mesh Landing and
/// the Room screens stand on, drawn identically on all of them (see
/// MeshBackground) — and around one persistent object, the beacon (see
/// [OnboardingStage]), which a spring carries from movement to movement:
/// the Tarkk mark between two phones becomes your face, and your face becomes
/// the first seat of a Room. The lines under it are handed over the way the
/// website swaps its panels ([StepSwap]), and every step sends one wave
/// through the mesh from the beacon, so each tap reads as one gesture.
///
/// The last movement does not end the journey, it continues it: Create and
/// Join lead straight into the existing Room flows — creation (with a name
/// already suggested from the callsign) and the invite scanner — as
/// *continuations* of this screen ([ContinuityPage]): this scene recedes, the
/// Room formation flies on into the creation screen as a [Hero], and from
/// there the user lands in the channel exactly as Landing's own entry points
/// take them. Backing out of either returns here, on the last movement.
///
/// Profile and connection choices stay in [OnboardingCubit] until one of the
/// final actions persists them all at once; skipping marks onboarding done and
/// touches nothing else. With [replay] (Settings → Startup) the last movement
/// simply finishes and pops back.
class OnboardingPage extends StatefulWidget {
  const OnboardingPage._({required this.replay});

  final bool replay;

  /// [initialStep]/[initialName] deep-link a movement (and a callsign) for
  /// tests and screenshots; the real app always starts at hello with an
  /// empty handle.
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
  /// The beacon's pose, 0 → 1 → 2, moved by a spring rather than a tween so a
  /// tap mid-flight redirects it with its momentum instead of restarting it.
  late final AnimationController _pose = AnimationController.unbounded(
    vsync: this,
  );

  /// Lightly under-damped: the beacon arrives with a hint of give, like a
  /// physical thing settling, and is still within a hair of rest in ~600ms.
  static const _spring = SpringDescription(
    mass: 1,
    stiffness: 150,
    damping: 19,
  );

  /// The lines' hand-over clock (see [StepSwap]); also plays the very first
  /// entrance.
  late final AnimationController _swap = AnimationController(
    vsync: this,
    duration: _swapDuration,
  );

  static const _swapDuration = Duration(milliseconds: 860);

  /// The beacon assembling itself on first sight (see [OnboardingStage.intro]).
  late final AnimationController _intro = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1400),
  );

  /// Slow loop for the light on the signal line and the orbiting arc.
  late final AnimationController _ambient = AnimationController(
    vsync: this,
    duration: const Duration(seconds: 8),
  );

  /// One wavefront through the mesh per step.
  late final AnimationController _wave = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1400),
  );

  int _shown = 0;
  int? _leaving;
  int _dir = 1;

  /// A final action is persisting or navigating; ignores a second tap until
  /// it is done (or the user comes back from the Room screen).
  bool _busy = false;
  bool _started = false;

  @override
  void initState() {
    super.initState();
    // The cubit may start past the first movement (a deep-link); the listener
    // only fires on *changes*, so seed the stage from it.
    _shown = context.read<OnboardingCubit>().state.step;
    _pose.value = _shown.toDouble();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _ambient.loopUnlessReduced(context);
    if (!_started) {
      _started = true;
      if (AppMotion.reduced(context)) {
        _swap.duration = AppMotion.sheet * 2;
        _intro.value = 1;
        _swap.forward();
      } else if (_shown == OnboardingCubit.helloStep) {
        // The first lines wait until the beacon has begun to assemble, so the
        // eye lands on it first. Keyed to the intro's own clock rather than a
        // timer, so it can never drift from what is on screen.
        void startLines() {
          if (_intro.value < 0.3) return;
          _intro.removeListener(startLines);
          _swap.forward();
          _wave.forward(from: 0);
        }

        _intro
          ..addListener(startLines)
          ..forward();
      } else {
        _intro.value = 1;
        _swap.forward();
        _wave.forward(from: 0);
      }
    }
  }

  @override
  void dispose() {
    _pose.dispose();
    _intro.dispose();
    _swap.dispose();
    _ambient.dispose();
    _wave.dispose();
    super.dispose();
  }

  void _onStepChanged(int step) {
    FocusManager.instance.primaryFocus?.unfocus();
    final forward = step > _shown;
    final reduced = AppMotion.reduced(context);
    if (forward) Sfx.play(SfxEvent.toggle);
    setState(() {
      _leaving = _shown;
      _dir = forward ? 1 : -1;
      _shown = step;
    });
    if (reduced) {
      _pose.value = step.toDouble();
    } else {
      _pose.animateWith(
        SpringSimulation(_spring, _pose.value, step.toDouble(), _pose.velocity),
      );
      _wave.forward(from: 0);
    }
    _swap.forward(from: 0).whenComplete(() {
      if (!mounted) return;
      setState(() => _leaving = null);
      if (forward && _shown == OnboardingCubit.roomStep) {
        // The Room has formed around you: land it with a firmer beat.
        Sfx.play(SfxEvent.peerJoin);
        HapticFeedback.mediumImpact();
      }
    });
  }

  // ── Endings ───────────────────────────────────────────────────────────────

  /// Makes the next screen a continuation of this one (see
  /// [ContinuityPage]): this scene's foreground recedes, the backdrop stays.
  static const _handoff = ContinuityHandoff();

  Future<void> _run(String tap, Future<void> Function() action) async {
    if (_busy) return;
    _busy = true;
    ScreenLog.tap(tap);
    try {
      await action();
    } finally {
      if (mounted) _busy = false;
    }
  }

  /// Create: everything is saved, then the Room creation screen continues
  /// this one with a name already suggested. It lands in the channel on its
  /// own (exactly as from Landing); backing out returns here.
  Future<void> _create(OnboardingCubit cubit) =>
      _run('OnboardingCreateRoom', () async {
        HapticFeedback.mediumImpact();
        await cubit.launch();
        if (!mounted) return;
        final name = cubit.state.name.trim();
        final location = Uri(
          path: AppRoutes.roomsPath,
          queryParameters: {
            'create': 'true',
            if (name.isNotEmpty)
              'name': context.getString.onbx_room_name_suggestion(name),
          },
        ).toString();
        await context.push(location, extra: _handoff);
      });

  /// Join: everything is saved, then the invite scanner continues this
  /// screen. A successful scan goes straight on into the Room's channel.
  Future<void> _join(OnboardingCubit cubit) =>
      _run('OnboardingJoinRoom', () async {
        HapticFeedback.mediumImpact();
        await cubit.launch();
        if (!mounted) return;
        await context.push(AppRoutes.roomQrJoinPath, extra: _handoff);
      });

  /// Later: everything is saved and Landing takes over — as a continuation,
  /// so the lobby rises out of this same scene.
  Future<void> _later(OnboardingCubit cubit) =>
      _run('OnboardingLater', () async {
        await cubit.finish();
        if (!mounted) return;
        context.go(AppRoutes.landingPath, extra: _handoff);
      });

  /// Replay (from Settings) ends by popping back, keeping any edits.
  Future<void> _finishReplay(OnboardingCubit cubit) =>
      _run('OnboardingDone', () async {
        HapticFeedback.mediumImpact();
        await cubit.finish();
        if (!mounted) return;
        context.pop();
      });

  Future<void> _skip(OnboardingCubit cubit) => _run('OnboardingSkip', () async {
    await cubit.skip();
    if (!mounted) return;
    if (widget.replay) {
      context.pop();
    } else {
      context.go(AppRoutes.landingPath, extra: _handoff);
    }
  });

  // ── Layout ────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    // The hello movement switches the theme live; AppColors is read
    // statically, so follow the switch explicitly.
    return ValueListenableBuilder<AppThemeMode>(
      valueListenable: ThemeService.mode,
      builder: (context, _, _) => AnnotatedRegion<SystemUiOverlayStyle>(
        value: AppColors.systemOverlayStyle,
        child: BlocConsumer<OnboardingCubit, OnboardingState>(
          listenWhen: (p, c) => p.step != c.step,
          listener: (_, state) {
            if (state.step != _shown) _onStepChanged(state.step);
          },
          builder: (context, state) {
            final cubit = context.read<OnboardingCubit>();
            return PopScope(
              // System back walks the journey backwards; only the first
              // movement lets the page go (exits on first run, returns to
              // Settings in replay).
              canPop: state.step == 0,
              onPopInvokedWithResult: (didPop, _) {
                if (!didPop) cubit.back();
              },
              child: Scaffold(
                backgroundColor: AppColors.background,
                body: Stack(
                  children: [
                    Positioned.fill(
                      child: MeshBackground(
                        wave: _wave,
                        waveOrigin: _waveOrigin(context),
                      ),
                    ),
                    // Everything but the backdrop: what recedes when a Room
                    // screen continues this one.
                    ContinuityRecede(
                      child: SafeArea(
                        child: LayoutBuilder(
                          builder: (context, constraints) =>
                              _scene(context, cubit, state, constraints),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            );
          },
        ),
      ),
    );
  }

  /// The stage takes about a third of the screen; with the keyboard up it
  /// gives way to the field, and on a short phone it goes entirely.
  ({double height, double scale}) _stageMetrics(
    BuildContext context,
    double available,
  ) {
    final normal = (available * 0.35).clamp(150.0, 290.0);
    final keyboard = _keyboardUp;
    if (!keyboard) {
      return (height: normal, scale: (normal / 230).clamp(0.62, 1.22));
    }
    // With the keyboard up the field matters more than the picture: the
    // stage keeps only what the title, field and key leave over, and steps
    // out entirely rather than shrink into a smudge.
    final room = available - _headerHeight - 74 - 250;
    final height = room < 110 ? 0.0 : room.clamp(110.0, normal);
    return (height: height, scale: (height / 230).clamp(0.45, 1.22));
  }

  static const _headerHeight = 56.0;

  /// Read from the page's own context: the Scaffold strips the keyboard
  /// inset out of the MediaQuery its body sees (it has already resized the
  /// body for it), so asking from inside the body always says "no keyboard".
  bool get _keyboardUp => MediaQuery.viewInsetsOf(context).bottom > 0;

  Offset _waveOrigin(BuildContext context) {
    final size = MediaQuery.sizeOf(context);
    if (size.height == 0) return const Offset(0.5, 0.25);
    final padding = MediaQuery.paddingOf(context);
    final available = size.height - padding.vertical;
    final stage = _stageMetrics(context, available).height;
    return Offset(0.5, (padding.top + _headerHeight + stage / 2) / size.height);
  }

  Widget _scene(
    BuildContext context,
    OnboardingCubit cubit,
    OnboardingState state,
    BoxConstraints constraints,
  ) {
    final stage = _stageMetrics(context, constraints.maxHeight);
    final keyboard = _keyboardUp;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _header(context, cubit, state),
        AnimatedContainer(
          duration: AppMotion.reduced(context)
              ? Duration.zero
              : AppMotion.sheet,
          curve: AppMotion.drawer,
          height: stage.height,
          child: stage.height == 0
              ? null
              : OnboardingStage(
                  pose: _pose,
                  ambient: _ambient,
                  intro: _intro,
                  avatarId: state.avatarId,
                  scale: stage.scale,
                  formationWidth: constraints.maxWidth - 48,
                ),
        ),
        Expanded(
          child: SingleChildScrollView(
            physics: const ClampingScrollPhysics(),
            padding: EdgeInsets.only(top: keyboard ? 4 : 8, bottom: 12),
            child: StepSwap(
              progress: _swap,
              direction: _dir,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              incoming: _lines(context, _shown),
              leaving: _leaving == null ? null : _lines(context, _leaving!),
            ),
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(24, 4, 24, 12),
          child: _actionZone(context, cubit, state),
        ),
      ],
    );
  }

  List<Widget> _lines(BuildContext context, int step) => [
    for (final line in switch (step) {
      OnboardingCubit.helloStep => OnboardingMovements.hello(context),
      OnboardingCubit.identityStep => OnboardingMovements.identity(
        context,
        onSubmit: context.read<OnboardingCubit>().next,
      ),
      _ => OnboardingMovements.room(context, replay: widget.replay),
    })
      OnboardingMovements.inset(line),
  ];

  // ── Header: back · progress · skip ────────────────────────────────────────

  Widget _header(
    BuildContext context,
    OnboardingCubit cubit,
    OnboardingState state,
  ) {
    final s = context.getString;
    final canSkip = state.step < OnboardingCubit.roomStep;
    return FadeTransition(
      opacity: _swap.drive(
        CurveTween(curve: const Interval(0, 0.5, curve: AppMotion.easeOut)),
      ),
      child: SizedBox(
        height: _headerHeight,
        child: Stack(
          alignment: Alignment.center,
          children: [
            OnboardingProgress(
              step: state.step,
              count: OnboardingCubit.stepCount,
            ),
            Align(
              alignment: AlignmentDirectional.centerStart,
              child: _Reveal(
                visible: state.step > 0,
                child: IconButton(
                  key: const Key('onboarding-back'),
                  tooltip: MaterialLocalizations.of(context).backButtonTooltip,
                  onPressed: cubit.back,
                  icon: Icon(
                    Icons.arrow_back_rounded,
                    color: AppColors.textSecondary,
                  ),
                ),
              ),
            ),
            Align(
              alignment: AlignmentDirectional.centerEnd,
              child: Padding(
                padding: const EdgeInsetsDirectional.only(end: 10),
                child: _Reveal(
                  visible: canSkip,
                  child: OnboardingQuietLink(
                    key: const Key('onboarding-skip'),
                    label: s.onboarding_skip,
                    uppercase: true,
                    onTap: () => unawaited(_skip(cubit)),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  // ── Actions: the one key, which becomes the way into a Room ──────────────

  /// Hello and you share one key that only changes its words. On the last
  /// movement the key steps aside for the two ways into a Room — the very
  /// cards Landing shows — and a quiet "later".
  Widget _actionZone(
    BuildContext context,
    OnboardingCubit cubit,
    OnboardingState state,
  ) {
    final s = context.getString;
    final roomActions =
        state.step == OnboardingCubit.roomStep && !widget.replay;
    final reduced = AppMotion.reduced(context);
    final Widget child;
    if (roomActions) {
      child = KeyedSubtree(
        key: const ValueKey('room-actions'),
        child: StepSwap(
          progress: _swap,
          incoming: [
            RoomEntryActions(
              hero: RoomEntryAction(
                key: const Key('onboarding-create-room'),
                icon: Icons.add_home_work_outlined,
                label: s.entry_create_room,
                hint: s.entry_create_room_hint,
                variant: RoomEntryVariant.hero,
                onTap: () => unawaited(_create(cubit)),
              ),
              alternatives: [
                RoomEntryAction(
                  key: const Key('onboarding-join-room'),
                  icon: Icons.qr_code_scanner_rounded,
                  label: s.entry_join_qr,
                  hint: s.entry_join_qr_hint,
                  variant: RoomEntryVariant.wide,
                  onTap: () => unawaited(_join(cubit)),
                ),
              ],
            ),
            const SizedBox(height: 2),
            Center(
              child: OnboardingQuietLink(
                key: const Key('onboarding-later'),
                label: s.onbx_later,
                onTap: () => unawaited(_later(cubit)),
              ),
            ),
          ],
        ),
      );
    } else {
      final last = state.step == OnboardingCubit.roomStep;
      child = KeyedSubtree(
        key: const ValueKey('primary'),
        child: OnboardingPrimaryButton(
          key: const Key('onboarding-primary'),
          label: switch (state.step) {
            OnboardingCubit.helloStep => s.onboarding_begin,
            OnboardingCubit.roomStep => s.onboarding_finish,
            _ => s.onboarding_continue,
          },
          enabled: state.canContinue,
          breathing: state.step == OnboardingCubit.helloStep || last,
          onTap: () {
            if (last) {
              unawaited(_finishReplay(cubit));
            } else {
              cubit.next();
            }
          },
        ),
      );
    }
    // The key and the cards trade places with the same hand-over as the
    // lines above them: the key sinks away, the cards rise in.
    return AnimatedSwitcher(
      duration: reduced ? AppMotion.card : const Duration(milliseconds: 420),
      reverseDuration: AppMotion.chip,
      switchInCurve: AppMotion.easeOut,
      switchOutCurve: AppMotion.leaving,
      layoutBuilder: (current, previous) => Stack(
        alignment: Alignment.bottomCenter,
        children: [...previous, ?current],
      ),
      transitionBuilder: (child, animation) {
        final fade = FadeTransition(opacity: animation, child: child);
        if (reduced) return fade;
        return SlideTransition(
          position: Tween<Offset>(
            begin: const Offset(0, 0.18),
            end: Offset.zero,
          ).animate(animation),
          child: fade,
        );
      },
      child: child,
    );
  }
}

/// A header affordance that fades away (and stops taking taps) when it has
/// nothing to offer on this movement.
class _Reveal extends StatelessWidget {
  const _Reveal({required this.visible, required this.child});

  final bool visible;
  final Widget child;

  @override
  Widget build(BuildContext context) => AnimatedOpacity(
    duration: AppMotion.card,
    curve: AppMotion.easeOut,
    opacity: visible ? 1 : 0,
    child: IgnorePointer(
      ignoring: !visible,
      child: ExcludeSemantics(excluding: !visible, child: child),
    ),
  );
}
