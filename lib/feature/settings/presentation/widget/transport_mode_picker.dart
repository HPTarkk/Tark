import 'package:flutter/material.dart';
import 'package:get_it/get_it.dart';

import '../../../../core/beta/beta_badge.dart';
import '../../../../core/beta/beta_intro.dart';
import '../../../../core/diagnostics/screen_log.dart';
import '../../../../core/entitlement/license_gate.dart';
import '../../../../core/entitlement/subscription_gate_page.dart';
import '../../../../core/entitlement/premium_feature.dart';
import '../../../../core/l10n/extension.dart';
import '../../../../core/motion/app_motion.dart';
import '../../../../core/theme/app_colors.dart';
import '../../../../core/widget/segmented_track.dart';
import '../../../transfer/api/transfer_api.dart';

/// Chooses a transport explicitly. Old automatic preferences display as
/// Wi-Fi/Hotspot, which is now the default; Bluetooth remains opt-in.
///
/// Wi-Fi/Hotspot carries a lock without entitlement: tapping it opens the
/// paywall instead of switching, so the transport gate is never a dead end.
/// Bluetooth is never locked. Guest is free and carries the Beta mark instead
/// — and, while pinned, a short beta note under the picker.
class TransportModePicker extends StatelessWidget {
  const TransportModePicker({super.key});

  bool _isWifiGroup(TransferMode? mode) =>
      mode == null || mode == TransferMode.wifi || mode == TransferMode.hotspot;

  @override
  Widget build(BuildContext context) {
    final s = context.getString;
    final store = GetIt.instance<TransferModeStore>();
    final gate = GetIt.instance<LicenseGate>();
    // Outer stream is entitlement, inner is the pin: a purchase completing in
    // the paywall has to unlock the buttons here without the user backing out
    // of Settings and coming back.
    return StreamBuilder<void>(
      stream: gate.changes,
      builder: (context, _) {
        final unlocked = gate.allows(PremiumFeature.wifiTransport);
        return StreamBuilder<TransferMode?>(
          initialData: store.pinnedMode,
          stream: store.pinChanges,
          builder: (context, snapshot) {
            final pinned = snapshot.data;
            Future<void> select(TransferMode target) async {
              ScreenLog.tap('Transport ${target.name}');
              if (target.requiresPremium && !unlocked) {
                if (!await openSubscriptionGate(
                  context,
                  PremiumFeature.wifiTransport,
                  onFreeAlternative: () async {
                    if (context.mounted) {
                      await store.setPinnedMode(TransferMode.bluetooth);
                    }
                  },
                )) {
                  return;
                }
              }
              if (context.mounted) await store.setPinnedMode(target);
            }

            return Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                SegmentedTrack<_Choice>(
                  stacked: true,
                  value: pinned == TransferMode.bluetooth
                      ? _Choice.bluetooth
                      : pinned == TransferMode.guest
                      ? _Choice.guest
                      : _Choice.wifi,
                  // Shown as selected while still locked (the default
                  // nobody has paid for yet): the tap opens the plans.
                  onReselected: (choice) {
                    if (choice == _Choice.wifi && !unlocked) {
                      select(pinned ?? TransferMode.wifi);
                    }
                  },
                  onChanged: (choice) => select(switch (choice) {
                    // Leave an existing hotspot pin alone — only switch to
                    // plain WiFi when coming from a different group.
                    _Choice.wifi =>
                      _isWifiGroup(pinned)
                          ? pinned ?? TransferMode.wifi
                          : TransferMode.wifi,
                    _Choice.bluetooth => TransferMode.bluetooth,
                    _Choice.guest => TransferMode.guest,
                  }),
                  segments: [
                    TrackSegment(
                      value: _Choice.wifi,
                      icon: Icons.wifi_rounded,
                      label: s.transport_wifi_hotspot,
                      // Locked stays tappable — the tap is what opens the
                      // paywall. Dimming carries "not yours yet".
                      dimmed: !unlocked,
                      semanticsHint: unlocked ? null : s.invite_method_locked,
                      mark: unlocked
                          ? null
                          : Icon(
                              Icons.lock_rounded,
                              size: 11,
                              color: AppColors.amber.withAlpha(200),
                            ),
                    ),
                    TrackSegment(
                      value: _Choice.bluetooth,
                      icon: Icons.bluetooth_rounded,
                      label: s.transport_bluetooth,
                    ),
                    TrackSegment(
                      value: _Choice.guest,
                      icon: Icons.qr_code_rounded,
                      label: s.transport_guest,
                      mark: TransferMode.guest.betaFeature != null
                          ? const BetaMark(size: 12)
                          : null,
                    ),
                  ],
                ),
                // Disclosed only while Guest is the pick: the mark on the
                // button says "beta", this says what that means for you.
                AnimatedSize(
                  duration: AppMotion.card,
                  curve: AppMotion.easeOut,
                  alignment: AlignmentDirectional.topCenter,
                  child: pinned?.betaFeature == null
                      ? const SizedBox(width: double.infinity)
                      : Padding(
                          padding: const EdgeInsets.only(top: 10),
                          child: BetaNotice(
                            feature: pinned!.betaFeature!,
                            message: s.beta_guest_notice,
                          ),
                        ),
                ),
                const SizedBox(height: 10),
                Text(
                  s.settings_transport_desc,
                  style: TextStyle(
                    color: AppColors.textSecondary,
                    fontSize: 11.5,
                    height: 1.5,
                  ),
                ),
              ],
            );
          },
        );
      },
    );
  }
}

/// The three things the picker offers. Wi-Fi and the hotspot bridge are one
/// choice here: the same sockets on a local network.
enum _Choice { wifi, bluetooth, guest }
