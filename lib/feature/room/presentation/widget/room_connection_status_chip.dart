import 'package:flutter/material.dart';

import '../../../../core/l10n/extension.dart';
import '../../../../core/motion/app_motion.dart';
import '../../../../core/theme/app_colors.dart';
import 'room_connection_status_scope.dart';

/// Small localized status used by both the pre-live roster and live Room list.
///
/// Existing product strings are reused so RTL/LTR behavior stays inside the
/// generated localization layer and this component never falls back to
/// carrier-specific wording such as Host, Join, SSID or IP.
class RoomConnectionStatusChip extends StatelessWidget {
  const RoomConnectionStatusChip({required this.phase, super.key});

  final RoomConnectionUiPhase phase;

  @override
  Widget build(BuildContext context) {
    final s = context.getString;
    final label = switch (phase) {
      RoomConnectionUiPhase.invited => s.people_waiting,
      RoomConnectionUiPhase.confirming => s.preflight_peer_unconfirmed,
      RoomConnectionUiPhase.readyToConnect => s.landing_ready,
      RoomConnectionUiPhase.connecting => s.connecting,
      RoomConnectionUiPhase.connected => s.preflight_transport_ready,
      RoomConnectionUiPhase.reconnecting => s.preflight_transport_degraded,
      RoomConnectionUiPhase.away => s.room_member_away,
    };
    final icon = switch (phase) {
      RoomConnectionUiPhase.invited => Icons.mail_outline_rounded,
      RoomConnectionUiPhase.confirming => Icons.hourglass_top_rounded,
      RoomConnectionUiPhase.readyToConnect =>
        Icons.check_circle_outline_rounded,
      RoomConnectionUiPhase.connecting => Icons.sync_rounded,
      RoomConnectionUiPhase.connected => Icons.check_circle_rounded,
      RoomConnectionUiPhase.reconnecting => Icons.sync_problem_rounded,
      RoomConnectionUiPhase.away => Icons.hourglass_bottom_rounded,
    };
    final active = phase == RoomConnectionUiPhase.connected;
    final away = phase == RoomConnectionUiPhase.away;
    final accent = active
        ? AppColors.green
        : away
        ? AppColors.amber
        : AppColors.textSecondary;

    return Semantics(
      label: label,
      // The chip eases to its new colour and the icon and label crossfade, so
      // a member going from "connecting" to "connected" reads as a change
      // rather than a flicker.
      child: AnimatedContainer(
        duration: AppMotion.chip,
        curve: AppMotion.easeOut,
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        decoration: BoxDecoration(
          color: active || away
              ? accent.withValues(alpha: 0.10)
              : AppColors.border.withValues(alpha: 0.55),
          borderRadius: BorderRadius.circular(8),
        ),
        child: AnimatedSize(
          duration: AppMotion.chip,
          curve: AppMotion.easeOut,
          child: AnimatedSwitcher(
            duration: AppMotion.chip,
            switchInCurve: AppMotion.easeOut,
            switchOutCurve: AppMotion.leaving,
            child: Row(
              key: ValueKey('room-status-${phase.name}'),
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(icon, size: 13, color: accent),
                const SizedBox(width: 5),
                Flexible(
                  child: Text(
                    label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: accent,
                      fontSize: 10,
                      fontWeight: FontWeight.w700,
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
