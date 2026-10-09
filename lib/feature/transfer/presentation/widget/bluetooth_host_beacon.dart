import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../../../core/l10n/extension.dart';
import '../../../../core/theme/app_colors.dart';
import '../manager/bluetooth_connect_cubit.dart';
import 'bluetooth_signal_scene.dart';
import 'bluetooth_wifi_bridge_hint.dart';

/// Host waiting screen: pulsing beacon ripples while advertising for a peer.
class BluetoothHostBeacon extends StatelessWidget {
  const BluetoothHostBeacon({super.key, required this.state});
  final BluetoothConnectState state;

  @override
  Widget build(BuildContext context) {
    final s = context.getString;
    return Align(
      alignment: AlignmentDirectional.topCenter,
      child: ListView(
        padding: const EdgeInsets.fromLTRB(24, 12, 24, 24),
        children: [
          const SizedBox(height: 12),
          const BluetoothSignalScene(phase: BluetoothSignalPhase.hosting),
          const SizedBox(height: 28),
          Text(
            s.bt_waiting_for_peer,
            textAlign: TextAlign.center,
            style: TextStyle(
              color: AppColors.textPrimary,
              fontSize: 18,
              fontWeight: FontWeight.w700,
            ),
          ),
          // Discoverability is a timed grant on Android: once it lapses the
          // beacon still pulses but no scanning phone can see it. Offer the
          // re-arm here rather than popping the system dialog unprompted.
          if (!state.hostDiscoverable) ...[
            const SizedBox(height: 18),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 24),
              child: _DiscoverableAgainCard(
                onTap: () =>
                    context.read<BluetoothConnectCubit>().makeDiscoverable(),
              ),
            ),
          ],
          if (state.bleUnavailable) ...[
            const SizedBox(height: 18),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 24),
              child: BluetoothWifiBridgeHint(message: s.bt_ble_unavailable),
            ),
          ],
          const SizedBox(height: 18),
          if (state.myName.isNotEmpty)
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 9),
              decoration: BoxDecoration(
                color: AppColors.card,
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: AppColors.border),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    s.bt_visible_as,
                    style: TextStyle(
                      color: AppColors.textSecondary,
                      fontSize: 10,
                      fontWeight: FontWeight.w700,
                      letterSpacing: 1.5,
                    ),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    state.myName,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: AppColors.amber,
                      fontSize: 13,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                ],
              ),
            ),
          const SizedBox(height: 12),
        ],
      ),
    );
  }
}

/// Shown when the host's findable window has run out — one tap re-asks the
/// system for it, which is all that stands between a pulsing beacon and a
/// joiner whose scan comes up empty.
class _DiscoverableAgainCard extends StatelessWidget {
  final VoidCallback onTap;

  const _DiscoverableAgainCard({required this.onTap});

  @override
  Widget build(BuildContext context) {
    final s = context.getString;
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: AppColors.amber.withAlpha(14),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: AppColors.amber.withAlpha(70)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                Icons.visibility_off_rounded,
                color: AppColors.amber,
                size: 18,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  s.bt_not_discoverable,
                  style: TextStyle(
                    color: AppColors.textSecondary,
                    fontSize: 11.5,
                    height: 1.45,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          GestureDetector(
            onTap: onTap,
            child: Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(vertical: 12),
              decoration: BoxDecoration(
                color: AppColors.amber.withAlpha(25),
                borderRadius: BorderRadius.circular(10),
                border: Border.all(
                  color: AppColors.amber.withAlpha(120),
                  width: 1.5,
                ),
              ),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(
                    Icons.podcasts_rounded,
                    color: AppColors.amber,
                    size: 16,
                  ),
                  const SizedBox(width: 8),
                  Text(
                    s.bt_make_discoverable,
                    style: TextStyle(
                      color: AppColors.amber,
                      fontSize: 11.5,
                      fontWeight: FontWeight.w800,
                      letterSpacing: 1.2,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
