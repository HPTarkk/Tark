import 'package:flutter/material.dart';

import '../../../../core/l10n/extension.dart';
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
      RoomConnectionUiPhase.invited => s.lobby_held_seats_hint,
      RoomConnectionUiPhase.confirming => s.preflight_peer_unconfirmed,
      RoomConnectionUiPhase.readyToConnect => s.landing_ready,
      RoomConnectionUiPhase.connecting => s.connecting,
      RoomConnectionUiPhase.connected => s.preflight_transport_ready,
      RoomConnectionUiPhase.reconnecting => s.preflight_transport_degraded,
    };
    final icon = switch (phase) {
      RoomConnectionUiPhase.invited => Icons.mail_outline_rounded,
      RoomConnectionUiPhase.confirming => Icons.hourglass_top_rounded,
      RoomConnectionUiPhase.readyToConnect =>
        Icons.check_circle_outline_rounded,
      RoomConnectionUiPhase.connecting => Icons.sync_rounded,
      RoomConnectionUiPhase.connected => Icons.check_circle_rounded,
      RoomConnectionUiPhase.reconnecting => Icons.sync_problem_rounded,
    };
    final active = phase == RoomConnectionUiPhase.connected;
    final accent = active ? AppColors.green : AppColors.textSecondary;

    return Semantics(
      label: label,
      child: Container(
        key: ValueKey('room-status-${phase.name}'),
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        decoration: BoxDecoration(
          color: active
              ? AppColors.green.withValues(alpha: 0.10)
              : AppColors.border.withValues(alpha: 0.55),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Row(
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
    );
  }
}
