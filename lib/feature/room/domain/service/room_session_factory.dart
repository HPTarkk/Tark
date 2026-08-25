import '../entity/room.dart';
import '../entity/room_session.dart';
import 'room_session_runtime.dart';

/// Builds a live [RoomSessionRuntime] only from canonical durable Room state.
///
/// This is the boundary that prevents presentation/transport code from using a
/// ChannelId, IP address, SSID, or temporary host role as the logical Room
/// identity. Merely selecting/viewing a saved Room still creates no transport;
/// callers invoke [open] explicitly when the user starts a live session.
abstract final class RoomSessionFactory {
  static RoomSessionRuntime? open(
    SavedRoom saved, {
    required String sessionId,
    bool initiallyMuted = false,
  }) {
    final normalizedSessionId = sessionId.trim();
    if (normalizedSessionId.isEmpty ||
        saved.room.archived ||
        !saved.membership.active) {
      return null;
    }

    final localMemberId = saved.membership.localMemberId;
    final activeMembers = saved.room.members
        .where((member) => member.isActive)
        .toList(growable: false);
    final localMembershipIsCanonical = activeMembers.any(
      (member) => member.id == localMemberId,
    );
    if (!localMembershipIsCanonical) return null;

    return RoomSessionRuntime(
      initialState: RoomSession.open(
        roomId: saved.room.id.value,
        sessionId: normalizedSessionId,
        localMemberId: localMemberId.value,
        memberIds: activeMembers.map((member) => member.id.value),
        isMuted: initiallyMuted,
      ),
    );
  }
}
