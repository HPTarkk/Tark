import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:get_it/get_it.dart';
import 'package:go_router/go_router.dart';

import '../../../../core/l10n/extension.dart';
import '../../../../core/motion/app_motion.dart';
import '../../../../core/router/routes.dart';
import '../../../../core/theme/app_colors.dart';
import '../../../../core/utils/logger.dart';
import '../../../../core/widget/link_established.dart';
import '../../../../core/widget/mesh_background.dart';
import '../../domain/entity/bluetooth_connection_state.dart';
import '../../domain/entity/bluetooth_role.dart';
import '../manager/bluetooth_connect_cubit.dart';
import '../widget/bluetooth_resume_beacon.dart';
import '../widget/hotspot_shared_widgets.dart';

/// Cold start after a Bluetooth call: find the same phone again, then ask.
///
/// Opened instead of Landing when the last call ran over Bluetooth (see
/// `QuickAccess.shouldResumeBluetooth`). It reuses the Bluetooth page's own
/// hands-free resume — a host re-hosts, a joiner keeps dialing the remembered
/// phone — and only adds the frame around it:
///
/// - one animated screen with a Cancel, instead of the host/join screens;
/// - a hard [_giveUpAfter] limit, after which it drops back to Landing with a
///   short note rather than searching forever for a phone that is not coming;
/// - once linked, a question — the channel only opens when the user says so,
///   and "Not now" closes the link rather than leaving it open unseen.
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

enum _Phase { starting, searching, connected, leaving }

class _BluetoothResumePageState extends State<BluetoothResumePage>
    with SingleTickerProviderStateMixin {
  static const _giveUpAfter = Duration(seconds: 30);

  late final AnimationController _countdown = AnimationController(
    vsync: this,
    duration: _giveUpAfter,
  );

  _Phase _phase = _Phase.starting;
  Timer? _giveUp;

  /// Whether the link came up. Kept apart from [_phase] so the success view
  /// stays put while leaving, instead of flashing back to the search as the
  /// cubit resets underneath the route transition.
  bool _linked = false;

  /// Set once the success animation has had its moment, so the question
  /// arrives after the link visibly lands rather than on top of it.
  bool _askReady = false;

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
  }

  @override
  void dispose() {
    _giveUp?.cancel();
    _countdown.dispose();
    super.dispose();
  }

  void _onState(BuildContext context, BluetoothConnectState state) {
    switch (_phase) {
      case _Phase.starting || _Phase.leaving:
        return;
      case _Phase.searching:
        if (state.connectionState == BluetoothConnectionState.connected) {
          _giveUp?.cancel();
          _countdown.stop();
          HapticFeedback.mediumImpact();
          setState(() {
            _phase = _Phase.connected;
            _linked = true;
          });
          Future<void>.delayed(LinkEstablished.hold, () {
            if (mounted && _phase == _Phase.connected) {
              setState(() => _askReady = true);
            }
          });
        } else if (state.role == null) {
          // The cubit gave up on its own (hosting refused to start, or a
          // one-shot attempt timed out) — same outcome as running out of time.
          _leave(failed: true);
        }
      case _Phase.connected:
        // The link fell apart while the question was up.
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
    setState(() => _phase = _Phase.leaving);
    _giveUp?.cancel();
    _countdown.stop();
    context.read<BluetoothConnectCubit>().backToRoleSelection();
    final messenger = ScaffoldMessenger.maybeOf(context);
    final note = context.getString.bt_resume_failed;
    context.goNamed(AppRoutes.landingName);
    if (failed) {
      messenger?.showSnackBar(
        SnackBar(
          content: Text(note),
          behavior: SnackBarBehavior.floating,
          duration: const Duration(seconds: 5),
        ),
      );
    }
  }

  void _enterChannel() {
    if (_phase != _Phase.connected) return;
    setState(() => _phase = _Phase.leaving);
    try {
      // Same hand-off as the Bluetooth page: the link was just established
      // here, so a selected Room goes live rather than back to its lobby.
      context.goNamed(
        AppRoutes.walkieName,
        queryParameters: const {'ride': 'true'},
      );
    } catch (e) {
      Logger.log('Walkie navigation failed: $e');
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
                    child: AnimatedSwitcher(
                      duration: AppMotion.sheet,
                      switchInCurve: AppMotion.easeOut,
                      switchOutCurve: AppMotion.leaving,
                      child: _linked
                          ? _Connected(
                              key: const ValueKey('connected'),
                              state: state,
                              askReady: _askReady,
                              onEnter: _enterChannel,
                              onNotNow: _leave,
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

class _Connected extends StatelessWidget {
  const _Connected({
    super.key,
    required this.state,
    required this.askReady,
    required this.onEnter,
    required this.onNotNow,
  });

  final BluetoothConnectState state;
  final bool askReady;
  final VoidCallback onEnter;
  final VoidCallback onNotNow;

  @override
  Widget build(BuildContext context) {
    final s = context.getString;
    final peerName = state.lastPeer?.name ?? '';
    final detail = state.role == BluetoothRole.joiner && peerName.isNotEmpty
        ? s.bt_resume_connected_to(peerName)
        : s.bt_resume_connected;
    return Column(
      children: [
        const Spacer(flex: 3),
        LinkEstablished(label: s.bt_connected, detail: detail),
        const Spacer(flex: 2),
        AnimatedOpacity(
          opacity: askReady ? 1 : 0,
          duration: AppMotion.entrance,
          curve: AppMotion.easeOut,
          child: AnimatedSlide(
            offset: askReady ? Offset.zero : const Offset(0, 0.15),
            duration: AppMotion.entrance,
            curve: AppMotion.easeOut,
            child: IgnorePointer(
              ignoring: !askReady,
              child: Column(
                children: [
                  Text(
                    s.bt_resume_ask,
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      color: AppColors.textPrimary,
                      fontSize: 16,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 18),
                  HotspotPrimaryButton(
                    icon: Icons.podcasts_rounded,
                    label: s.hotspot_enter_channel,
                    onTap: onEnter,
                  ),
                  const SizedBox(height: 10),
                  _GhostButton(label: s.bt_resume_not_now, onTap: onNotNow),
                ],
              ),
            ),
          ),
        ),
        const SizedBox(height: 20),
      ],
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
