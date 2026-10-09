import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../../../core/l10n/extension.dart';
import '../../../../core/motion/app_motion.dart';
import '../../../../core/recovery/bounded_retry.dart';
import '../../../../core/theme/app_colors.dart';
import '../../domain/entity/bluetooth_peer.dart';
import '../manager/bluetooth_connect_cubit.dart';
import 'bluetooth_signal_scene.dart';

/// Joiner screen: rotating radar sweep with discovered peers as blips, plus
/// the tappable peer list below it.
class BluetoothJoinerRadar extends StatefulWidget {
  final BluetoothConnectState state;

  const BluetoothJoinerRadar({super.key, required this.state});

  @override
  State<BluetoothJoinerRadar> createState() => _BluetoothJoinerRadarState();
}

class _BluetoothJoinerRadarState extends State<BluetoothJoinerRadar>
    with WidgetsBindingObserver {
  /// How long the list stays honestly blank before it says so. The scan only
  /// surfaces Tark hosts, so a room full of headsets now looks identical to an
  /// empty room — and an empty panel under a sweeping radar reads as broken
  /// rather than as "nobody is hosting yet". Long enough that a host coming up
  /// at the same moment lands first.
  static const _emptyHintAfter = Duration(seconds: 6);

  Timer? _emptyHintTimer;
  bool _searchedAWhile = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _emptyHintTimer = Timer(_emptyHintAfter, () {
      if (mounted) setState(() => _searchedAWhile = true);
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _emptyHintTimer?.cancel();
    super.dispose();
  }

  /// Back from the settings screen: start the search if Location is on now.
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed && widget.state.locationOff) {
      unawaited(context.read<BluetoothConnectCubit>().recheckLocation());
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = context.getString;
    final state = widget.state;
    final connecting = state.connectingPeerId != null;
    final connectingPeer = connecting
        ? state.peers.where((p) => p.id == state.connectingPeerId).firstOrNull
        : null;

    return CustomScrollView(
      slivers: [
        SliverToBoxAdapter(
          child: Column(
            children: [
              const SizedBox(height: 8),
              SizedBox(
                height: (MediaQuery.sizeOf(context).height * .3).clamp(
                  150,
                  240,
                ),
                child: BluetoothSignalScene(
                  phase: connecting
                      ? BluetoothSignalPhase.connecting
                      : BluetoothSignalPhase.searching,
                  peers: state.peers.length,
                ),
              ),
              const SizedBox(height: 14),
              Text(
                connecting
                    // A nameless peer just drops off the end — better a bare
                    // "Hooking up..." than one trailed by an address. Once the
                    // automatic re-dials have been going a while the lead-in
                    // softens, so a slow connect stops looking like a frozen one.
                    ? '${state.dialRetry == RetryPhase.stillTrying ? s.bt_still_trying : s.bt_connecting} '
                              '${connectingPeer?.name ?? state.lastPeer?.name ?? ''}'
                          .trimRight()
                    : s.bt_scanning,
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: AppColors.textPrimary,
                  fontSize: 18,
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: 8),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 28),
                child: AnimatedSwitcher(
                  duration: AppMotion.card,
                  child: Text(
                    connecting
                        ? s.bt_signal_link_hint
                        : s.bt_signal_search_hint,
                    key: ValueKey(connecting),
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      color: AppColors.textSecondary,
                      fontSize: 12,
                      height: 1.6,
                    ),
                  ),
                ),
              ),
              // Escape hatch, mainly for the hands-free auto-reconnect: one tap
              // back to role selection for users who meant to host or pick a
              // different peer this time.
              if (connecting)
                TextButton(
                  onPressed: () => context
                      .read<BluetoothConnectCubit>()
                      .backToRoleSelection(),
                  child: Text(
                    s.cancel,
                    style: TextStyle(
                      color: AppColors.textSecondary,
                      fontSize: 11,
                      fontWeight: FontWeight.w700,
                      letterSpacing: 1.5,
                    ),
                  ),
                ),
              const SizedBox(height: 14),
            ],
          ),
        ),
        if (state.locationOff)
          SliverToBoxAdapter(
            child: _LocationOffNote(
              message: s.bt_location_off,
              actionLabel: s.hotspot_enable_location,
              onAction: () => unawaited(
                context.read<BluetoothConnectCubit>().openLocationSettings(),
              ),
            ),
          )
        else if (state.peers.isEmpty)
          SliverToBoxAdapter(
            child: Align(
              alignment: Alignment.topCenter,
              child: AnimatedOpacity(
                duration: const Duration(milliseconds: 400),
                opacity: _searchedAWhile && !connecting ? 1 : 0,
                child: Text(
                  s.bt_no_devices_found,
                  style: TextStyle(
                    color: AppColors.textSecondary,
                    fontSize: 12,
                  ),
                ),
              ),
            ),
          )
        else
          SliverPadding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
            sliver: SliverList.separated(
              itemCount: state.peers.length,
              separatorBuilder: (_, _) => const SizedBox(height: 8),
              itemBuilder: (context, index) {
                final peer = state.peers[index];
                return _PeerTile(
                  peer: peer,
                  isConnecting: state.connectingPeerId == peer.id,
                  enabled: !connecting,
                  connectingLabel: s.bt_connecting,
                  onTap: () =>
                      context.read<BluetoothConnectCubit>().connectTo(peer),
                );
              },
            ),
          ),
      ],
    );
  }
}

/// Why the search isn't running, and the one switch that fixes it.
class _LocationOffNote extends StatelessWidget {
  final String message;
  final String actionLabel;
  final VoidCallback onAction;

  const _LocationOffNote({
    required this.message,
    required this.actionLabel,
    required this.onAction,
  });

  @override
  Widget build(BuildContext context) {
    return Align(
      alignment: Alignment.topCenter,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.location_off_rounded, color: AppColors.amber, size: 28),
            const SizedBox(height: 10),
            Text(
              message,
              textAlign: TextAlign.center,
              style: TextStyle(color: AppColors.textSecondary, fontSize: 13),
            ),
            const SizedBox(height: 12),
            TextButton.icon(
              onPressed: onAction,
              icon: Icon(Icons.my_location_rounded, color: AppColors.amber),
              label: Text(
                actionLabel,
                style: TextStyle(
                  color: AppColors.amber,
                  fontSize: 12,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 1.2,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _PeerTile extends StatelessWidget {
  final BluetoothPeer peer;
  final bool isConnecting;
  final bool enabled;
  final String connectingLabel;
  final VoidCallback onTap;

  const _PeerTile({
    required this.peer,
    required this.isConnecting,
    required this.enabled,
    required this.connectingLabel,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      enabled: enabled,
      child: GestureDetector(
        onTap: enabled ? onTap : null,
        child: AnimatedOpacity(
          duration: const Duration(milliseconds: 200),
          opacity: !enabled && !isConnecting ? 0.4 : 1.0,
          child: AnimatedContainer(
            duration: AppMotion.card,
            curve: AppMotion.easeOut,
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
            decoration: BoxDecoration(
              color: AppColors.card,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(
                color: isConnecting ? AppColors.amber : AppColors.border,
              ),
            ),
            child: Row(
              children: [
                if (isConnecting)
                  Icon(
                    Icons.bluetooth_searching_rounded,
                    color: AppColors.amber,
                    size: 20,
                  )
                else
                  // Amber marks a device hosting from inside the app, which is
                  // all the list normally holds — the cubit drops everything a
                  // classic inquiry sweeps up. A reconnect target waiting on a
                  // stale adapter name is the one entry that lands here muted.
                  Icon(
                    Icons.bluetooth_rounded,
                    color: peer.isAppHost
                        ? AppColors.amber
                        : AppColors.textSecondary,
                    size: 20,
                  ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        peer.name.isEmpty
                            ? context.getString.bt_unnamed_device
                            : peer.name,
                        style: TextStyle(
                          color: AppColors.textPrimary,
                          fontSize: 14,
                        ),
                        overflow: TextOverflow.ellipsis,
                      ),
                      if (isConnecting)
                        Text(
                          connectingLabel,
                          style: TextStyle(
                            color: AppColors.amber,
                            fontSize: 11,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                _TransportBadge(isBle: peer.isBle),
                const SizedBox(width: 10),
                _SignalBars(bars: peer.signalBars),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _TransportBadge extends StatelessWidget {
  final bool isBle;

  const _TransportBadge({required this.isBle});

  @override
  Widget build(BuildContext context) {
    final color = isBle ? AppColors.amber : AppColors.green;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: color.withAlpha(20),
        borderRadius: BorderRadius.circular(5),
        border: Border.all(color: color.withAlpha(110), width: 0.8),
      ),
      child: Text(
        isBle ? 'BLE' : 'BT',
        style: TextStyle(
          color: color,
          fontSize: 8.5,
          fontWeight: FontWeight.w800,
          letterSpacing: 0.8,
        ),
      ),
    );
  }
}

class _SignalBars extends StatelessWidget {
  final int bars; // 0..4

  const _SignalBars({required this.bars});

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.end,
      children: [
        for (var i = 0; i < 4; i++) ...[
          if (i > 0) const SizedBox(width: 2),
          AnimatedContainer(
            duration: const Duration(milliseconds: 300),
            width: 3,
            height: 5.0 + i * 3,
            decoration: BoxDecoration(
              color: i < bars ? AppColors.amber : AppColors.border,
              borderRadius: BorderRadius.circular(1),
            ),
          ),
        ],
      ],
    );
  }
}
