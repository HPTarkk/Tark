import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../../../core/l10n/app_localizations.dart';
import '../../../../core/l10n/extension.dart';
import '../../../../core/theme/app_colors.dart';
import '../../../../core/widget/qr_widgets.dart';
import '../../domain/entity/hotspot_credentials.dart';
import '../manager/wifi_hotspot_cubit.dart';
import 'hotspot_shared_widgets.dart';

/// Android host side of the hotspot bridge: shows the Wi-Fi QR + credentials
/// while waiting for the peer to scan it and join.
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
    final cubit = context.read<WifiHotspotCubit>();
    if (state.phase == HotspotPhase.error) {
      final code = state.errorCode;
      return HotspotErrorCard(
        message: _errorMessage(s, code),
        onRetry: cubit.startHost,
        fixLabel: _hasFixScreen(code) ? s.hotspot_open_settings : null,
        onFix: _hasFixScreen(code) ? cubit.openFixSettings : null,
        // Hosting is the half of the bridge that can fail; joining the other
        // phone's hotspot instead is almost always available.
        altLabel: s.hotspot_try_joining,
        onAlt: () => cubit.chooseRole(HotspotRole.join),
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
            child: GlowingQrCard(
              data: creds.wifiQrPayload,
              size: 216,
              branded: true,
            ),
          ),
        ),
        const SizedBox(height: 18),
        HotspotEntrance(
          delayMs: 140,
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
        // Owns its own entrance and its own spacing: it isn't on screen for
        // the first ten seconds, so a fixed gap here would reserve a hole for
        // something that may never appear.
        _ManualFallback(credentials: creds),
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

  /// The native side reports *why* the AP couldn't come up; each cause has a
  /// different thing for the user to do, and the old catch-all ("turn off
  /// tethering, check Location, try again") sent people chasing settings that
  /// were already fine.
  String _errorMessage(AppLocalizations s, String? code) => switch (code) {
    'tethering_on' => s.hotspot_error_tethering,
    'location_off' => s.hotspot_error_location,
    'permission_denied' => s.hotspot_error_permission,
    'no_channel' => s.hotspot_error_no_channel,
    'incompatible_mode' => s.hotspot_error_incompatible,
    'unsupported' => s.hotspot_error_unsupported,
    _ => s.hotspot_error,
  };

  bool _hasFixScreen(String? code) =>
      code == 'tethering_on' || code == 'location_off';
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

/// The way out when the camera won't do it: a line that opens the network name
/// and password — absent until it's needed.
///
/// The happy path is over in a few seconds, so for the first [_revealAfter]
/// there is nothing here at all: no credentials to copy down, no second way to
/// weigh, just the code. Only once the scan has visibly gone nowhere does the
/// line fade in and offer the manual route. Reading a name and password off
/// someone else's phone is the slower, more error-prone half of this screen;
/// it shouldn't be competing for attention while the fast path is still live.
class _ManualFallback extends StatefulWidget {
  final HotspotCredentials credentials;

  const _ManualFallback({required this.credentials});

  @override
  State<_ManualFallback> createState() => _ManualFallbackState();
}

class _ManualFallbackState extends State<_ManualFallback> {
  /// How long the scan gets before the manual route appears. Long enough to
  /// cover an unhurried happy path — pick up the other phone, open Tarkk,
  /// frame the code — and short enough that being stuck doesn't feel like it.
  static const _revealAfter = Duration(seconds: 10);

  bool _revealed = false;
  bool _open = false;
  Timer? _revealTimer;

  @override
  void initState() {
    super.initState();
    _revealTimer = Timer(_revealAfter, () {
      if (mounted) setState(() => _revealed = true);
    });
  }

  @override
  void dispose() {
    _revealTimer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // Takes up no room at all until revealed, so the screen above it doesn't
    // sit around a reserved gap — the pulse and the button just slide down
    // when it arrives.
    return AnimatedSize(
      duration: const Duration(milliseconds: 320),
      curve: Curves.easeOutCubic,
      alignment: Alignment.topCenter,
      child: _revealed
          ? HotspotEntrance(delayMs: 0, child: _buildContent(context))
          : const SizedBox(width: double.infinity, height: 0),
    );
  }

  Widget _buildContent(BuildContext context) {
    final s = context.getString;
    final tint = _open ? AppColors.amber : AppColors.textSecondary;
    return Column(
      children: [
        const SizedBox(height: 6),
        GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: () => setState(() => _open = !_open),
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 10),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                AnimatedRotation(
                  turns: _open ? 0.5 : 0,
                  duration: const Duration(milliseconds: 220),
                  child: Icon(
                    Icons.expand_more_rounded,
                    size: 17,
                    color: tint,
                  ),
                ),
                const SizedBox(width: 6),
                AnimatedDefaultTextStyle(
                  duration: const Duration(milliseconds: 300),
                  style: TextStyle(
                    color: tint,
                    fontSize: 12,
                    fontWeight: FontWeight.w700,
                     fontFamily: 'Vazirmatn',
                  ),
                  child: Text(
                    _open
                        ? s.hotspot_hide_credentials
                        : s.hotspot_show_credentials,
                  ),
                ),
              ],
            ),
          ),
        ),
        AnimatedSize(
          duration: const Duration(milliseconds: 240),
          curve: Curves.easeOutCubic,
          alignment: Alignment.topCenter,
          child: _open
              ? Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: _CredentialsCard(
                    ssidLabel: s.hotspot_network,
                    passwordLabel: s.hotspot_password,
                    credentials: widget.credentials,
                    copiedLabel: s.hotspot_copied,
                    note: s.hotspot_network_note,
                  ),
                )
              : const SizedBox(width: double.infinity, height: 0),
        ),
      ],
    );
  }
}

class _CredentialsCard extends StatelessWidget {
  final String ssidLabel;
  final String passwordLabel;
  final HotspotCredentials credentials;
  final String copiedLabel;

  /// Why the network isn't called "Tarkk". Android generates the SSID for a
  /// local-only hotspot and gives apps no way to set it (the overload that
  /// takes a SoftApConfiguration is a system API), so the machine-looking name
  /// gets explained rather than left to look like a bug.
  final String note;

  const _CredentialsCard({
    required this.ssidLabel,
    required this.passwordLabel,
    required this.credentials,
    required this.copiedLabel,
    required this.note,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 6, 16, 12),
      decoration: BoxDecoration(
        color: AppColors.card,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: AppColors.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
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
          const SizedBox(height: 2),
          Text(
            note,
            style: TextStyle(
              color: AppColors.textSecondary,
              fontSize: 11,
              height: 1.45,
            ),
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
