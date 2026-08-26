import '../entity/room.dart';
import '../repository/room_repository.dart';

/// Resolves the durable Room that should be shown in the pre-live lobby.
///
/// This is deliberately read-only: opening the lobby must never start a
/// transport, microphone, hotspot, or mutate Room selection. Invalid/stale
/// selection fails closed to null so legacy quick-access can keep its existing
/// behavior without inventing a hidden Room.
final class SelectedRoomLobbyResolver {
  const SelectedRoomLobbyResolver(this.rooms);

  final RoomRepository rooms;

  Future<SavedRoom?> resolve() async {
    final selectedId = await rooms.selectedRoomId();
    if (selectedId == null) return null;
    final saved = await rooms.get(selectedId);
    if (saved == null || saved.room.archived || !saved.membership.active) {
      return null;
    }
    final localMatches = saved.room.members.where(
      (member) =>
          member.id == saved.membership.localMemberId && member.isActive,
    );
    if (localMatches.length != 1) return null;
    return saved;
  }
}
