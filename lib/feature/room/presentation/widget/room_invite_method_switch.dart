import 'package:flutter/material.dart';

import '../../../../core/l10n/extension.dart';
import '../../../../core/motion/app_motion.dart';
import '../../../../core/theme/app_colors.dart';
import '../../../../core/widget/segmented_track.dart';
import '../../domain/entity/room_invite_link.dart';

/// "How should they connect?" — chosen by the host, on the code itself.
///
/// Two segments on one track, Hotspot and Bluetooth, with a thumb that
/// travels between them. Picking one re-makes the code under it, so what is
/// on screen is always the method the other phone will use; there is no
/// second screen and nothing to remember from Settings.
///
/// One line under the track says what the pick means for the person holding
/// the phone (range, and that a hotspot here does not share internet), never
/// how it works.
///
/// The track is the app's shared [SegmentedTrack]: a spring-driven thumb
/// that can be dragged, and that springs back from a pick the opener
/// refuses (a locked method whose paywall was closed).
class RoomInviteMethodSwitch extends StatelessWidget {
  const RoomInviteMethodSwitch({
    required this.value,
    required this.onChanged,
    this.hotspotLocked = false,
    this.bluetoothIsFree = false,
    super.key,
  });

  final RoomInviteMethod value;
  final ValueChanged<RoomInviteMethod> onChanged;

  /// Hotspot needs a subscription this phone does not have. The segment
  /// stays tappable: the tap is what opens the plans.
  final bool hotspotLocked;

  /// Whether to say Bluetooth is the free way, which only means something
  /// where something is sold.
  final bool bluetoothIsFree;

  @override
  Widget build(BuildContext context) {
    final s = context.getString;
    final bluetooth = value == RoomInviteMethod.bluetooth;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SegmentedTrack<RoomInviteMethod>(
          key: const Key('room-invite-method-switch'),
          semanticsLabel: s.invite_method_label,
          value: value,
          onChanged: onChanged,
          segments: [
            TrackSegment(
              segmentKey: const Key('room-invite-method-hotspot'),
              value: RoomInviteMethod.hotspot,
              icon: Icons.wifi_tethering_rounded,
              label: s.invite_method_hotspot,
              semanticsHint: hotspotLocked ? s.invite_method_locked : null,
              mark: hotspotLocked
                  ? Icon(
                      Icons.lock_rounded,
                      size: 12,
                      color: AppColors.amber.withValues(alpha: 0.8),
                    )
                  : null,
            ),
            TrackSegment(
              segmentKey: const Key('room-invite-method-bluetooth'),
              value: RoomInviteMethod.bluetooth,
              icon: Icons.bluetooth_rounded,
              label: s.invite_method_bluetooth,
            ),
          ],
        ),
        const SizedBox(height: 8),
        PhaseSwitcher(
          child: Text(
            bluetooth
                ? (bluetoothIsFree
                      ? s.invite_method_bluetooth_note_free
                      : s.invite_method_bluetooth_note)
                : s.invite_method_hotspot_note,
            key: ValueKey('room-invite-method-note-${value.name}'),
            textAlign: TextAlign.center,
            style: TextStyle(
              color: AppColors.textSecondary,
              fontSize: 12,
              height: 1.45,
            ),
          ),
        ),
      ],
    );
  }
}
