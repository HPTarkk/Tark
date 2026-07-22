import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../../../core/l10n/extension.dart';
import '../../../../core/theme/app_colors.dart';
import '../../domain/entity/hotspot_credentials.dart';
import '../manager/wifi_hotspot_cubit.dart';
import 'hotspot_qr_scanner.dart';
import 'hotspot_shared_widgets.dart';

/// Peer side of the hotspot bridge, on both platforms: scan the host's Wi-Fi QR
/// in the app's own scanner and join that network without leaving the app.
///
/// Android joins through a WifiNetworkSpecifier request (one system dialog),
/// iOS through NEHotspotConfiguration. Where neither works the manual card
/// takes over — and even then, "I've joined" pins this process to the network
/// so Android's no-internet fallback can't quietly move the session to
/// cellular.
class HotspotJoinFlow extends StatelessWidget {
  final HotspotBridgeState state;
  final VoidCallback onEnterChannel;

  const HotspotJoinFlow({
    super.key,
    required this.state,
    required this.onEnterChannel,
  });

  Future<void> _scan(BuildContext context) async {
    final cubit = context.read<WifiHotspotCubit>();
    final raw = await HotspotQrScannerPage.open(context);
    if (raw == null) return;
    await cubit.submitScannedCode(raw);
  }

  @override
  Widget build(BuildContext context) {
    final s = context.getString;
    final cubit = context.read<WifiHotspotCubit>();
    final creds = state.credentials;
    return ListView(
      padding: const EdgeInsets.fromLTRB(24, 16, 24, 24),
      children: [
        HotspotEntrance(
          delayMs: 0,
          child: Center(
            child: Container(
              width: 84,
              height: 84,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: AppColors.amber.withAlpha(20),
                border: Border.all(color: AppColors.amber.withAlpha(120)),
              ),
              child: Icon(
                Icons.wifi_find_rounded,
                color: AppColors.amber,
                size: 38,
              ),
            ),
          ),
        ),
        const SizedBox(height: 20),
        HotspotEntrance(
          delayMs: 80,
          child: Text(
            s.hotspot_join_instructions,
            textAlign: TextAlign.center,
            style: TextStyle(
              color: AppColors.textSecondary,
              fontSize: 13.5,
              height: 1.5,
            ),
          ),
        ),
        const SizedBox(height: 24),
        ...switch (state.joinPhase) {
          JoinPhase.joining => [HotspotPreparing(label: s.hotspot_joining)],
          JoinPhase.joined => [
            HotspotInlineNote(
              icon: Icons.check_circle_rounded,
              // Naming the network we actually landed on: the SSID is Android's
              // machine-generated one, so without it on screen there's no way
              // to tell a successful join from a join onto the wrong AP.
              text: creds == null
                  ? s.hotspot_joined
                  : s.hotspot_joined_network(creds.ssid),
              color: AppColors.green,
            ),
            const SizedBox(height: 12),
            Text(
              s.hotspot_join_waiting,
              textAlign: TextAlign.center,
              style: TextStyle(color: AppColors.textSecondary, fontSize: 12.5),
            ),
            const SizedBox(height: 18),
            HotspotPrimaryButton(
              icon: Icons.arrow_forward_rounded,
              label: s.hotspot_enter_channel,
              onTap: onEnterChannel,
            ),
          ],
          JoinPhase.manual when creds != null => [
            _ManualJoinCard(credentials: creds),
            const SizedBox(height: 18),
            HotspotPrimaryButton(
              icon: Icons.check_rounded,
              label: s.hotspot_manual_joined,
              onTap: cubit.confirmManualJoin,
            ),
            const SizedBox(height: 12),
            _SecondaryButton(
              label: s.hotspot_scan_again,
              onTap: () => _scan(context),
            ),
          ],
          JoinPhase.lost => [
            HotspotInlineNote(
              icon: Icons.link_off_rounded,
              text: s.hotspot_link_lost,
              color: AppColors.red,
            ),
            const SizedBox(height: 18),
            if (creds != null)
              HotspotPrimaryButton(
                icon: Icons.refresh_rounded,
                label: s.hotspot_rejoin,
                onTap: () => cubit.joinNetwork(creds),
              ),
            const SizedBox(height: 12),
            _SecondaryButton(
              label: s.hotspot_scan_again,
              onTap: () => _scan(context),
            ),
          ],
          _ => [
            if (state.joinPhase == JoinPhase.invalid) ...[
              HotspotInlineNote(
                icon: Icons.error_outline_rounded,
                text: s.hotspot_invalid_qr,
                color: AppColors.red,
              ),
              const SizedBox(height: 18),
            ],
            HotspotPrimaryButton(
              icon: Icons.qr_code_scanner_rounded,
              label: s.hotspot_scan_host,
              onTap: () => _scan(context),
            ),
          ],
        },
      ],
    );
  }
}

class _ManualJoinCard extends StatelessWidget {
  final HotspotCredentials credentials;

  const _ManualJoinCard({required this.credentials});

  @override
  Widget build(BuildContext context) {
    final s = context.getString;
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AppColors.card,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: AppColors.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            s.hotspot_manual_join_title,
            style: TextStyle(
              color: AppColors.textPrimary,
              fontSize: 13.5,
              fontWeight: FontWeight.w800,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            s.hotspot_manual_join_hint,
            style: TextStyle(
              color: AppColors.textSecondary,
              fontSize: 12,
              height: 1.5,
            ),
          ),
          const SizedBox(height: 6),
          HotspotCredentialRow(
            label: s.hotspot_network,
            value: credentials.ssid,
            copiedLabel: s.hotspot_copied,
          ),
          Divider(color: AppColors.border, height: 1),
          HotspotCredentialRow(
            label: s.hotspot_password,
            value: credentials.passphrase,
            copiedLabel: s.hotspot_copied,
          ),
        ],
      ),
    );
  }
}

class _SecondaryButton extends StatelessWidget {
  final String label;
  final VoidCallback onTap;

  const _SecondaryButton({required this.label, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.symmetric(vertical: 13),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: AppColors.border),
        ),
        child: Text(
          label,
          textAlign: TextAlign.center,
          style: TextStyle(
            color: AppColors.textSecondary,
            fontSize: 11.5,
            fontWeight: FontWeight.w800,
            letterSpacing: 1.3,
          ),
        ),
      ),
    );
  }
}
