import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../../../core/l10n/extension.dart';
import '../../../../core/theme/app_colors.dart';
import '../../../../core/widget/qr_widgets.dart';
import '../../domain/entity/hotspot_credentials.dart';
import '../manager/wifi_hotspot_cubit.dart';
import 'hotspot_shared_widgets.dart';

/// Android host side of the hotspot bridge: shows the Wi-Fi QR + credentials
/// while waiting for the iPhone to join.
class HotspotHostFlow extends StatelessWidget {
  final HotspotBridgeState state;
  final VoidCallback onEnterChannel;

  const HotspotHostFlow({
    super.key,
    required this.state,
    required this.onEnterChannel,
  });

  @override
  Widget build(BuildContext context) {
    final s = context.getString;
    if (state.phase == HotspotPhase.error) {
      return HotspotErrorCard(
        message: s.hotspot_error,
        onRetry: () => context.read<WifiHotspotCubit>().startHost(),
      );
    }
    final creds = state.credentials;
    if (state.phase == HotspotPhase.starting || creds == null) {
      return HotspotPreparing(label: s.hotspot_creating);
    }
    return ListView(
      padding: const EdgeInsets.fromLTRB(24, 8, 24, 24),
      children: [
        HotspotEntrance(
          delayMs: 0,
          child: Center(child: _HostBadge(label: s.hotspot_host_badge)),
        ),
        const SizedBox(height: 16),
        HotspotEntrance(
          delayMs: 80,
          child: Center(
            child: GlowingQrCard(data: creds.wifiQrPayload, size: 216),
          ),
        ),
        const SizedBox(height: 18),
        HotspotEntrance(
          delayMs: 140,
          child: _CredentialsCard(
            ssidLabel: s.hotspot_network,
            passwordLabel: s.hotspot_password,
            credentials: creds,
            copiedLabel: s.hotspot_copied,
          ),
        ),
        const SizedBox(height: 18),
        HotspotEntrance(
          delayMs: 200,
          child: Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: AppColors.card,
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: AppColors.border),
            ),
            child: Column(
              children: [
                StepRow(
                  index: 1,
                  icon: Icons.photo_camera_rounded,
                  text: s.hotspot_step_scan,
                ),
                const SizedBox(height: 12),
                Divider(color: AppColors.border, height: 1),
                const SizedBox(height: 12),
                StepRow(
                  index: 2,
                  icon: Icons.podcasts_rounded,
                  text: s.hotspot_step_join_channel,
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 18),
        HotspotEntrance(
          delayMs: 260,
          child: _WaitingPulse(label: s.hotspot_waiting),
        ),
        const SizedBox(height: 18),
        HotspotEntrance(
          delayMs: 320,
          child: HotspotPrimaryButton(
            icon: Icons.arrow_forward_rounded,
            label: s.hotspot_enter_channel,
            onTap: onEnterChannel,
          ),
        ),
      ],
    );
  }
}

class _HostBadge extends StatelessWidget {
  final String label;

  const _HostBadge({required this.label});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      decoration: BoxDecoration(
        color: AppColors.green.withAlpha(16),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: AppColors.green.withAlpha(110)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.wifi_tethering_rounded, color: AppColors.green, size: 13),
          const SizedBox(width: 6),
          Text(
            label,
            style: TextStyle(
              color: AppColors.green,
              fontSize: 9.5,
              fontWeight: FontWeight.w800,
              letterSpacing: 1.4,
            ),
          ),
        ],
      ),
    );
  }
}

class _CredentialsCard extends StatelessWidget {
  final String ssidLabel;
  final String passwordLabel;
  final HotspotCredentials credentials;
  final String copiedLabel;

  const _CredentialsCard({
    required this.ssidLabel,
    required this.passwordLabel,
    required this.credentials,
    required this.copiedLabel,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
      decoration: BoxDecoration(
        color: AppColors.card,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: AppColors.border),
      ),
      child: Column(
        children: [
          HotspotCredentialRow(
            label: ssidLabel,
            value: credentials.ssid,
            copiedLabel: copiedLabel,
          ),
          Divider(color: AppColors.border, height: 1),
          HotspotCredentialRow(
            label: passwordLabel,
            value: credentials.passphrase,
            copiedLabel: copiedLabel,
          ),
        ],
      ),
    );
  }
}

class _WaitingPulse extends StatefulWidget {
  final String label;

  const _WaitingPulse({required this.label});

  @override
  State<_WaitingPulse> createState() => _WaitingPulseState();
}

class _WaitingPulseState extends State<_WaitingPulse>
    with SingleTickerProviderStateMixin {
  late final AnimationController _pulse = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1400),
  )..repeat(reverse: true);

  @override
  void dispose() {
    _pulse.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return FadeTransition(
      opacity: Tween<double>(
        begin: 0.45,
        end: 1.0,
      ).animate(CurvedAnimation(parent: _pulse, curve: Curves.easeInOut)),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          SizedBox(
            width: 14,
            height: 14,
            child: CircularProgressIndicator(
              color: AppColors.amber,
              strokeWidth: 2,
            ),
          ),
          const SizedBox(width: 10),
          Text(
            widget.label,
            style: TextStyle(color: AppColors.textSecondary, fontSize: 13),
          ),
        ],
      ),
    );
  }
}
