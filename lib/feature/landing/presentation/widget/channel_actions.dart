import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../../core/l10n/app_localizations.dart';
import '../../../../core/l10n/extension.dart';
import '../../../../core/theme/app_colors.dart';
import '../../../transfer/api/transfer_api.dart';

/// The landing page's primary choice: start a channel, or join one.
///
/// **Why two buttons and not a transport picker.** The screen used to open on
/// "WIFI / HOTSPOT · BLUETOOTH · GUEST" — a question about the two phones'
/// surroundings, asked of the one person who cannot see both of them, with the
/// answer parked in Settings where it outlived the situation that produced it.
/// Two riders in a field with no Wi-Fi had to leave the main screen before the
/// app would do the only thing that could work there.
///
/// So the only question left on screen is the one the user is the sole
/// authority on — am I starting this, or arriving? — and [TransportAdvisor]
/// derives the rest. Each button then *says* what it derived, because a
/// decision made silently is indistinguishable from a decision made wrong: a
/// rider who taps START and watches a hotspot come up needs to know that was
/// the plan, not a malfunction.
class ChannelActions extends StatelessWidget {
  final ChannelPlan createPlan;
  final ChannelPlan joinPlan;

  /// 0..1 breath driving the primary action's border and glow.
  final double pulse;

  final bool enabled;
  final ValueChanged<ChannelPlan> onTap;

  /// Opens the hotspot bridge without an intent, for "we're on different
  /// networks" — the one thing the advisor provably cannot observe.
  final VoidCallback onDifferentNetwork;

  /// The mirror of [onDifferentNetwork]: "actually, we're already together" —
  /// switches both actions from the hotspot default over to the shared
  /// network this phone can already see.
  final VoidCallback onSameWifi;

  /// Whether this phone can currently see a Wi-Fi network at all — gates
  /// [onSameWifi], since offering to fall back to a network that does not
  /// exist would be a dead link.
  final bool hasWifi;

  const ChannelActions({
    super.key,
    required this.createPlan,
    required this.joinPlan,
    required this.pulse,
    required this.enabled,
    required this.onTap,
    required this.onDifferentNetwork,
    required this.onSameWifi,
    required this.hasWifi,
  });

  @override
  Widget build(BuildContext context) {
    final s = context.getString;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // The blurred glow under the primary action repaints on every frame of
        // the breath. Kept on its own layer so the identity card, the logo and
        // the secondary action above and below it are not re-rastered with it
        // — the low-end floor is a Galaxy S8+ holding 60fps.
        RepaintBoundary(
          child: _RoomActionButton(
            plan: createPlan,
            label: s.channel_create,
            icon: Icons.podcasts_rounded,
            primary: true,
            pulse: pulse,
            enabled: enabled && !createPlan.blocked,
            onTap: () => onTap(createPlan),
          ),
        ),
        // Guest is host-only: the far end is a browser, so there is nothing
        // here for "join" to do and a second button would lead nowhere.
        if (!joinPlan.hostOnly) ...[
          const SizedBox(height: 12),
          _RoomActionButton(
            plan: joinPlan,
            label: s.channel_join,
            icon: Icons.login_rounded,
            primary: false,
            pulse: pulse,
            enabled: enabled && !joinPlan.blocked,
            onTap: () => onTap(joinPlan),
          ),
        ],
        // Only worth offering while the plan still assumes one shared network.
        // Once it already routes through a hotspot, this is the thing it is
        // doing.
        if (createPlan.canFallBackToHotspot) ...[
          const SizedBox(height: 10),
          _WayOutLink(
            icon: Icons.wifi_tethering_rounded,
            label: s.channel_different_network,
            onTap: onDifferentNetwork,
          ),
        ],
        // The reverse case: the default assumed a hotspot, but there is a
        // network right here that both phones could just use instead.
        if (createPlan.canFallBackToWifi && hasWifi) ...[
          const SizedBox(height: 10),
          _WayOutLink(
            icon: Icons.wifi_rounded,
            label: s.channel_same_wifi,
            onTap: onSameWifi,
          ),
        ],
      ],
    );
  }
}

/// One channel action: a heading, and under it the route the advisor chose.
///
/// The primary variant carries the fill, the border pulse and the glow;
/// the secondary is the same shape drawn quietly. They are deliberately *not*
/// equal weight. Creating has to happen before joining can — there is nothing
/// to join until someone starts — so leading with it answers the question two
/// identical buttons would leave the user standing in front of.
class _RoomActionButton extends StatelessWidget {
  final ChannelPlan plan;
  final String label;
  final IconData icon;
  final bool primary;
  final double pulse;
  final bool enabled;
  final VoidCallback onTap;

  const _RoomActionButton({
    required this.plan,
    required this.label,
    required this.icon,
    required this.primary,
    required this.pulse,
    required this.enabled,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final s = context.getString;
    final accent = enabled ? AppColors.amber : AppColors.textSecondary;
    return GestureDetector(
      onTap: enabled
          ? () {
              HapticFeedback.selectionClick();
              onTap();
            }
          : null,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 300),
        padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 15),
        decoration: BoxDecoration(
          color: !enabled
              ? AppColors.border.withAlpha(40)
              : primary
              ? AppColors.amber.withAlpha(25)
              : AppColors.card,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(
            color: !enabled
                ? AppColors.border
                : primary
                ? Color.lerp(
                    AppColors.amber,
                    AppColors.amber.withAlpha(120),
                    pulse,
                  )!
                : AppColors.amber.withAlpha(90),
            width: 2,
          ),
          boxShadow: enabled && primary
              ? [
                  BoxShadow(
                    color: AppColors.amber.withAlpha((15 + 40 * pulse).toInt()),
                    blurRadius: 28,
                    spreadRadius: 2,
                  ),
                ]
              : null,
        ),
        child: Row(
          children: [
            Icon(icon, color: accent, size: 22),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    label,
                    style: TextStyle(
                      color: accent,
                      fontSize: 15,
                      fontWeight: FontWeight.w800,
                      letterSpacing: 2,
                    ),
                  ),
                  const SizedBox(height: 3),
                  Text(
                    routeLabel(s, plan),
                    style: TextStyle(
                      color: AppColors.textSecondary,
                      fontSize: 11,
                      height: 1.35,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// The one line under a channel action naming the route it will take.
///
/// Keyed on [ChannelPlanReason] rather than on the transport, because the two
/// hotspot ends are the same transport and opposite instructions — "this phone
/// makes the network" and "scan the other phone's code" — and a single
/// "over a hotspot" would be wrong for whichever end read it.
String routeLabel(AppLocalizations s, ChannelPlan plan) => switch (plan.reason) {
  ChannelPlanReason.sharedNetwork => s.channel_via_shared_network,
  ChannelPlanReason.ownHotspot => s.channel_via_own_hotspot,
  ChannelPlanReason.scanHostCode => s.channel_via_scan_code,
  ChannelPlanReason.bluetoothLink => s.channel_via_bluetooth,
  ChannelPlanReason.guestLink => s.channel_via_guest,
  ChannelPlanReason.noNetwork => s.channel_via_no_network,
};

class _WayOutLink extends StatelessWidget {
  final IconData icon;
  final String label;
  final VoidCallback onTap;

  const _WayOutLink({
    required this.icon,
    required this.label,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () {
        HapticFeedback.selectionClick();
        onTap();
      },
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(icon, size: 14, color: AppColors.textSecondary),
            const SizedBox(width: 7),
            Text(
              label,
              style: TextStyle(
                color: AppColors.textSecondary,
                fontSize: 12,
                fontWeight: FontWeight.w700,
                decoration: TextDecoration.underline,
                decorationColor: AppColors.textSecondary.withAlpha(90),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
