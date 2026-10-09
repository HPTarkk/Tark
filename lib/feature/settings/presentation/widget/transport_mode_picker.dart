import 'package:flutter/material.dart';
import 'package:get_it/get_it.dart';

import '../../../../core/diagnostics/screen_log.dart';
import '../../../../core/entitlement/license_gate.dart';
import '../../../../core/entitlement/subscription_gate_page.dart';
import '../../../../core/entitlement/premium_feature.dart';
import '../../../../core/l10n/extension.dart';
import '../../../../core/motion/app_motion.dart';
import '../../../../core/theme/app_colors.dart';
import '../../../transfer/api/transfer_api.dart';

/// Chooses a transport explicitly. Old automatic preferences display as
/// Wi-Fi/Hotspot, which is now the default; Bluetooth remains opt-in.
///
/// WiFi and Guest carry a lock without entitlement: tapping one opens the
/// paywall instead of switching, so the transport gate is never a dead end.
/// Bluetooth is never locked.
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
                Container(
                  padding: const EdgeInsets.all(4),
                  decoration: BoxDecoration(
                    color: AppColors.card,
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: AppColors.border),
                  ),
                  child: Row(
                    children: [
                      _ModeButton(
                        label: s.transport_wifi_hotspot,
                        icon: Icons.wifi_rounded,
                        selected: _isWifiGroup(pinned),
                        locked: !unlocked,
                        // Leave an existing hotspot pin alone — only switch to
                        // plain WiFi when coming from a different group.
                        onTap: () => select(
                          _isWifiGroup(pinned)
                              ? pinned ?? TransferMode.wifi
                              : TransferMode.wifi,
                        ),
                      ),
                      _ModeButton(
                        label: s.transport_bluetooth,
                        icon: Icons.bluetooth_rounded,
                        selected: pinned == TransferMode.bluetooth,
                        locked: false,
                        onTap: () => select(TransferMode.bluetooth),
                      ),
                      _ModeButton(
                        label: s.transport_guest,
                        icon: Icons.qr_code_rounded,
                        selected: pinned == TransferMode.guest,
                        locked: !unlocked,
                        onTap: () => select(TransferMode.guest),
                      ),
                    ],
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

class _ModeButton extends StatelessWidget {
  final String label;
  final IconData icon;
  final bool selected;
  final bool locked;
  final VoidCallback onTap;

  const _ModeButton({
    required this.label,
    required this.icon,
    required this.selected,
    required this.locked,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    // Locked buttons stay tappable — the tap is what opens the paywall.
    // Dimming carries the "not yours yet" signal instead of disabling.
    final foreground = selected
        ? AppColors.amber
        : locked
        ? AppColors.textSecondary.withAlpha(120)
        : AppColors.textSecondary;
    return Expanded(
      child: GestureDetector(
        onTap: onTap,
        child: AnimatedContainer(
          duration: AppMotion.card,
          curve: AppMotion.easeOut,
          padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 2),
          decoration: BoxDecoration(
            color: selected ? AppColors.amber.withAlpha(25) : null,
            borderRadius: BorderRadius.circular(9),
            border: selected
                ? Border.all(color: AppColors.amber.withAlpha(140))
                : null,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Stack(
                clipBehavior: Clip.none,
                children: [
                  Icon(icon, size: 16, color: foreground),
                  if (locked)
                    Positioned(
                      right: -6,
                      top: -4,
                      child: Icon(
                        Icons.lock_rounded,
                        size: 10,
                        color: AppColors.amber.withAlpha(200),
                      ),
                    ),
                ],
              ),
              const SizedBox(height: 4),
              Text(
                label,
                textAlign: TextAlign.center,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: foreground,
                  fontSize: 9,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 0.2,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
