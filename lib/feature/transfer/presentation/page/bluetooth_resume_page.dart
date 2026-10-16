import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:get_it/get_it.dart';

import '../../../../core/l10n/extension.dart';
import '../../../../core/motion/app_motion.dart';
import '../../../../core/motion/scene_turn.dart';
import '../../../../core/motion/route_arrival.dart';
import '../../../../core/router/route_exit.dart';
import '../../../../core/router/routes.dart';
import '../../../../core/theme/app_colors.dart';
import '../../../../core/utils/logger.dart';
import '../../../../core/widget/connection_journey.dart';
import '../../../../core/widget/mesh_background.dart';
import '../../domain/entity/bluetooth_connection_state.dart';
import '../../domain/entity/bluetooth_role.dart';
import '../manager/bluetooth_connect_cubit.dart';
import '../widget/bluetooth_resume_beacon.dart';

/// Cold start after a Classic Bluetooth call: find the same phone again.
///
/// Opened instead of Landing when the last call ran over Bluetooth (see
/// `QuickAccess.shouldResumeBluetooth`). It reuses the Bluetooth page's own
/// hands-free resume — a host re-hosts, a joiner keeps dialing the remembered
/// phone — and only adds the frame around it:
///
/// - one animated screen with a Cancel, instead of the host/join screens;
/// - a hard [_giveUpAfter] limit, followed by an animated failure result;
/// - an animated success result when linked, then Home with the link ready.
///   Starting a conversation remains an explicit action from Home.
///
/// When the cubit decides not to resume at all (a permission missing, the
/// radio off), the screen steps aside to Landing without a word: nothing was
/// attempted, so there is nothing to report.
class BluetoothResumePage extends StatefulWidget {
  const BluetoothResumePage._();

  static Widget buildPage() => BlocProvider<BluetoothConnectCubit>(
    create: (_) => GetIt.instance<BluetoothConnectCubit>(),
    child: const BluetoothResumePage._(),
  );

  @override
  State<BluetoothResumePage> createState() => _BluetoothResumePageState();
}

enum _Phase { starting, searching, connected, failed, leaving }

class _BluetoothResumePageState extends State<BluetoothResumePage>
    with TickerProviderStateMixin, RouteArrival<BluetoothResumePage> {
  static const _giveUpAfter = Duration(seconds: 30);

  /// How long the failure stays up, once it has played, before Landing:
  /// time to read why.
  static const _failureRead = Duration(milliseconds: 1800);

  /// How long the success is on screen before Home: the established beat
  /// lands and holds.
  static const _successShown = Duration(milliseconds: 1200);

  late final AnimationController _countdown = AnimationController(
    vsync: this,
    duration: _giveUpAfter,
  );

  /// The failure beat (the tether decohering into static), counted in
  /// frames: a phone that drops frames still gets to show all of it before
  /// the reading time starts.
  late final AnimationController _failureBeat = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1100),
  );

  _Phase _phase = _Phase.starting;
  Timer? _giveUp;
  Timer? _successHold;
  Timer? _failureHold;

  /// Whether the link came up. Kept apart from [_phase] so the success view
  /// stays put while leaving, instead of flashing back to the search as the
  /// cubit resets underneath the route transition.
  bool _linked = false;
  bool _failed = false;
  bool _routeArrived = false;

  @override
  void initState() {
    super.initState();
    unawaited(_begin());
  }

  Future<void> _begin() async {
    final started = await context.read<BluetoothConnectCubit>().autoResume;
    if (!mounted || _phase != _Phase.starting) return;
    if (!started) {
      _leave();
      return;
    }
    setState(() => _phase = _Phase.searching);
    _countdown.forward();
    _giveUp = Timer(_giveUpAfter, () => _leave(failed: true));
    final current = context.read<BluetoothConnectCubit>().state;
    if (current.connectionState == BluetoothConnectionState.connected) {
      _onState(context, current);
    }
  }

  @override
  void onRouteArrived() {
    _routeArrived = true;
    final current = context.read<BluetoothConnectCubit>().state;
    if (_phase == _Phase.searching &&
        current.connectionState == BluetoothConnectionState.connected) {
      _onState(context, current);
    }
  }

  @override
  void dispose() {
    _giveUp?.cancel();
    _successHold?.cancel();
    _failureHold?.cancel();
    _countdown.dispose();
    _failureBeat.dispose();
    super.dispose();
  }

  void _onState(BuildContext context, BluetoothConnectState state) {
    switch (_phase) {
      case _Phase.starting || _Phase.failed || _Phase.leaving:
        return;
      case _Phase.searching:
        if (state.connectionState == BluetoothConnectionState.connected) {
          if (!_routeArrived) return;
          _giveUp?.cancel();
          _countdown.stop();
          HapticFeedback.mediumImpact();
          setState(() {
            _phase = _Phase.connected;
            _linked = true;
          });
          _successHold = Timer(_successShown + AppMotion.sheet, _finishSuccess);
        } else if (state.role == null) {
          // The cubit gave up on its own (hosting refused to start, or a
          // one-shot attempt timed out) — same outcome as running out of time.
          _leave(failed: true);
        }
      case _Phase.connected:
        // The link fell apart while the success result was up.
        if (state.role == null ||
            state.connectionState == BluetoothConnectionState.error ||
            state.connectionState == BluetoothConnectionState.disconnected) {
          _leave(failed: true);
        }
    }
  }

  /// Back to Landing, closing whatever link or attempt is in flight.
  void _leave({bool failed = false}) {
    if (_phase == _Phase.leaving || !mounted) return;
    if (failed) {
      if (_phase == _Phase.failed) return;
      setState(() {
        _phase = _Phase.failed;
        _failed = true;
      });
      _giveUp?.cancel();
      _successHold?.cancel();
      _countdown.stop();
      unawaited(_holdFailure());
      context.read<BluetoothConnectCubit>().backToRoleSelection();
      return;
    }
    setState(() => _phase = _Phase.leaving);
    _giveUp?.cancel();
    _failureHold?.cancel();
    _countdown.stop();
    if (!_failed) context.read<BluetoothConnectCubit>().backToRoleSelection();
    goBackTo(context, AppRoutes.landingPath);
  }

  Future<void> _holdFailure() async {
    try {
      if (AppMotion.reduced(context)) {
        _failureBeat.value = 1;
      } else {
        await _failureBeat.forward().orCancel;
      }
    } on TickerCanceled {
      // Left (or disposed) mid-beat: nothing more to schedule.
      return;
    }
    if (!mounted || _phase != _Phase.failed) return;
    _failureHold = Timer(_failureRead, _finishFailure);
  }

  void _finishFailure() {
    if (!mounted || _phase != _Phase.failed) return;
    setState(() => _phase = _Phase.leaving);
    goBackTo(context, AppRoutes.landingPath);
  }

  void _finishSuccess() {
    if (_phase != _Phase.connected) return;
    if (context.read<BluetoothConnectCubit>().state.connectionState !=
        BluetoothConnectionState.connected) {
      _leave(failed: true);
      return;
    }
    setState(() => _phase = _Phase.leaving);
    try {
      // Keep the established link ready; Home is an explicit pause before
      // anyone starts a conversation or opens a microphone. This screen sits
      // over Home, so getting there is a step back out of it.
      goBackTo(context, AppRoutes.landingPath);
    } catch (e) {
      Logger.log('Resume navigation failed: $e');
      if (mounted) setState(() => _phase = _Phase.connected);
    }
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      // System back is Cancel: this page is the whole stack on cold start, so
      // letting the pop through would close the app instead of reaching
      // Landing — and would leave the attempt running underneath.
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _leave();
      },
      child: AnnotatedRegion<SystemUiOverlayStyle>(
        value: AppColors.systemOverlayStyle,
        child: Scaffold(
          backgroundColor: AppColors.background,
          body: BlocConsumer<BluetoothConnectCubit, BluetoothConnectState>(
            listener: _onState,
            builder: (context, state) => Stack(
              children: [
                const Positioned.fill(child: MeshBackground()),
                SafeArea(
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 28),
                    child: SceneTurn(
                      motion: SceneMotion.through,
                      scene: _failed || _linked ? 'resume-result' : 'searching',
                      depth: _failed || _linked ? 1 : 0,
                      // Success and failure are one scene under one key, so a
                      // link lost while the success is up snaps in place
                      // rather than swapping screens.
                      child: _failed || _linked
                          ? _Result(
                              key: const ValueKey('resume-result'),
                              state: state,
                              failed: _failed,
                            )
                          : _Searching(
                              key: const ValueKey('searching'),
                              state: state,
                              countdown: _countdown,
                              onCancel: _leave,
                            ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _Searching extends StatelessWidget {
  const _Searching({
    super.key,
    required this.state,
    required this.countdown,
    required this.onCancel,
  });

  final BluetoothConnectState state;
  final Animation<double> countdown;
  final VoidCallback onCancel;

  @override
  Widget build(BuildContext context) {
    final s = context.getString;
    final peerName = state.lastPeer?.name ?? '';
    final headline = state.role == BluetoothRole.joiner && peerName.isNotEmpty
        ? s.bt_resume_looking_for(peerName)
        : s.bt_resume_waiting;
    return Column(
      children: [
        const Spacer(flex: 3),
        Text(
          s.bt_resume_title.toUpperCase(),
          textAlign: TextAlign.center,
          style: TextStyle(
            color: AppColors.amber,
            fontSize: 12,
            fontWeight: FontWeight.w800,
            letterSpacing: 2,
          ),
        ),
        const SizedBox(height: 28),
        BluetoothResumeBeacon(countdown: countdown),
        const SizedBox(height: 32),
        AnimatedSwitcher(
          duration: AppMotion.card,
          transitionBuilder: HandOver.transition(),
          child: Text(
            headline,
            key: ValueKey(headline),
            textAlign: TextAlign.center,
            style: TextStyle(
              color: AppColors.textPrimary,
              fontSize: 18,
              fontWeight: FontWeight.w700,
            ),
          ),
        ),
        const SizedBox(height: 8),
        Text(
          s.bt_resume_hint,
          textAlign: TextAlign.center,
          style: TextStyle(color: AppColors.textSecondary, fontSize: 13),
        ),
        const Spacer(flex: 4),
        _GhostButton(label: s.cancel, onTap: onCancel),
        const SizedBox(height: 20),
      ],
    );
  }
}

/// How the resume ended, told in the Bluetooth beat of the app's one
/// [ConnectionJourney] scene: the tether locking in, or decohering into
/// static.
class _Result extends StatefulWidget {
  const _Result({super.key, required this.state, required this.failed});

  final BluetoothConnectState state;
  final bool failed;

  @override
  State<_Result> createState() => _ResultState();
}

class _ResultState extends State<_Result> {
  /// The peer's name as of the success, so it is not lost when the cubit
  /// resets under a failure.
  String? _detail;

  @override
  Widget build(BuildContext context) {
    final s = context.getString;
    if (!widget.failed || _detail == null) {
      final peerName = widget.state.lastPeer?.name ?? '';
      _detail = widget.state.role == BluetoothRole.joiner && peerName.isNotEmpty
          ? s.bt_resume_connected_to(peerName)
          : s.bt_resume_connected;
    }
    return ConnectionJourney(
      stage: widget.failed ? JourneyStage.failed : JourneyStage.established,
      link: JourneyLink.bluetooth,
      title: widget.failed ? s.bt_resume_not_connected : s.bt_connected,
      detail: widget.failed ? s.bt_resume_failed : _detail,
    );
  }
}

class _GhostButton extends StatelessWidget {
  const _GhostButton({required this.label, required this.onTap});

  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: double.infinity,
      child: TextButton(
        onPressed: onTap,
        style: TextButton.styleFrom(
          padding: const EdgeInsets.symmetric(vertical: 14),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(14),
            side: BorderSide(color: AppColors.border),
          ),
        ),
        child: Text(
          label,
          style: TextStyle(
            color: AppColors.textSecondary,
            fontSize: 13,
            fontWeight: FontWeight.w700,
            letterSpacing: 1.5,
          ),
        ),
      ),
    );
  }
}
