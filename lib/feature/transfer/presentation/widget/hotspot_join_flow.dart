import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../../../core/l10n/extension.dart';
import '../../../../core/theme/app_colors.dart';
import '../../domain/entity/hotspot_credentials.dart';
import '../manager/wifi_hotspot_cubit.dart';
import 'hotspot_qr_scanner.dart';
import 'hotspot_join_states.dart';
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

  /// A system switch the join needs and can't reach: state it, offer the one
  /// tap that gets there, and leave a way back in.
  ///
  /// The way back is a button rather than an automatic retry because neither
  /// switch reports back — the Wi-Fi panel and the Location screen are both
  /// the user's to close, and nothing tells us when they have.
  List<Widget> _blockedSwitch(
    BuildContext context, {
    required IconData icon,
    required String message,
    required IconData actionIcon,
    required String actionLabel,
    required VoidCallback onAction,
    required HotspotCredentials? credentials,
  }) {
    final s = context.getString;
    final cubit = context.read<WifiHotspotCubit>();
    return [
      HotspotInlineNote(icon: icon, text: message, color: AppColors.red),
      const SizedBox(height: 18),
      HotspotPrimaryButton(
        icon: actionIcon,
        label: actionLabel,
        onTap: onAction,
      ),
      const SizedBox(height: 12),
      if (credentials != null)
        _SecondaryButton(
          label: s.hotspot_rejoin,
          onTap: () => cubit.joinNetwork(credentials),
        ),
    ];
  }

  /// The one graphic at the top of the screen, chosen by phase.
  ///
  /// Keyed so [AnimatedSwitcher] cross-fades between them; without a key it
  /// sees "a widget" both sides of a phase change and swaps the contents in
  /// place, which loses the transition that makes the states feel connected.
  Widget _headerGraphic(Color color) => switch (state.joinPhase) {
    JoinPhase.joining => const HotspotReachPulse(key: ValueKey('reaching')),
    JoinPhase.joined => const HotspotJoinedPulse(
      key: ValueKey('listening'),
      size: 84,
    ),
    // Idle and every failure: still hunting, or waiting to be pointed at
    // something. The magnifier is right for all of them.
    _ => Container(
      key: const ValueKey('idle'),
      width: 84,
      height: 84,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: color.withAlpha(20),
        border: Border.all(color: color.withAlpha(120)),
      ),
      child: Icon(Icons.wifi_find_rounded, color: color, size: 38),
    ),
  };

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
    // The standing "scan the host's QR code" paragraph belongs to the empty
    // screen and nothing else. It used to render above the phase switch
    // unconditionally, so it stayed up through every later state — stacked on
    // top of a spinner while joining, and on top of "joined <ssid>" once we
    // were already on the network, telling the user to do a thing they had
    // just finished doing.
    //
    // Every other phase says something specific of its own directly below:
    // a loader for [JoinPhase.joining], the success note and Enter button for
    // [JoinPhase.joined], and a message-with-a-fix for each failure. None of
    // them is improved by generic instructions above it.
    final joined = state.joinPhase == JoinPhase.joined;
    final showInstructions = state.joinPhase == JoinPhase.idle;
    final headerColor = joined ? AppColors.green : AppColors.amber;
    return ListView(
      padding: const EdgeInsets.fromLTRB(24, 16, 24, 24),
      children: [
        HotspotEntrance(
          delayMs: 0,
          child: Center(
            // One graphic carries the state, rather than a static badge with a
            // second indicator underneath it. Stacking them put two green
            // circles and a green tick on screen at once the moment the join
            // succeeded, which reads as three separate pieces of good news for
            // one event.
            child: SizedBox(
              height: 84,
              child: AnimatedSwitcher(
                duration: const Duration(milliseconds: 320),
                child: _headerGraphic(headerColor),
              ),
            ),
          ),
        ),
        const SizedBox(height: 20),
        if (showInstructions) ...[
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
        ] else
          const SizedBox(height: 8),
        ...switch (state.joinPhase) {
          // The header is already showing the reaching arcs, so this is the
          // caption for them and nothing more.
          JoinPhase.joining => [
            Text(
              s.hotspot_joining,
              textAlign: TextAlign.center,
              style: TextStyle(color: AppColors.textSecondary, fontSize: 13),
            ),
          ],
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
          // Both of these sit ahead of the manual card deliberately. They mean
          // the phone can't see Wi-Fi networks at all, so the manual card's
          // "pick this network in Settings" would be a dead end — there is
          // nothing in the list to pick.
          JoinPhase.wifiOff => _blockedSwitch(
            context,
            icon: Icons.wifi_off_rounded,
            message: s.hotspot_wifi_off,
            actionIcon: Icons.wifi_rounded,
            actionLabel: s.hotspot_enable_wifi,
            onAction: cubit.enableWifiAndRetry,
            credentials: creds,
          ),
          JoinPhase.locationOff => _blockedSwitch(
            context,
            icon: Icons.location_off_rounded,
            message: s.hotspot_location_off,
            actionIcon: Icons.my_location_rounded,
            actionLabel: s.hotspot_enable_location,
            onAction: cubit.openLocationSettings,
            credentials: creds,
          ),
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
