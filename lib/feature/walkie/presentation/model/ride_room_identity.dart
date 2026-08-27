import '../../../room/domain/entity/room.dart';
import '../../../room/domain/repository/room_repository.dart';

/// Durable Room identity rendered on the live Ride surface.
///
/// This is deliberately derived from canonical Room state, never ChannelId,
/// IP/SSID, device names or any transport-local identifier.
final class RideRoomIdentity {
  const RideRoomIdentity({required this.name, required this.code});

  final String name;
  final String code;

  factory RideRoomIdentity.fromSavedRoom(SavedRoom saved) {
    final raw = saved.room.id.value.toUpperCase();
    final prefix = raw.substring(0, 8);
    return RideRoomIdentity(
      name: saved.room.name,
      code: '${prefix.substring(0, 4)}-${prefix.substring(4)}',
    );
  }
}

/// Resolves the currently selected durable Room for Ride Mode presentation.
///
/// Missing, archived or inactive selections fail closed: the Ride surface
/// simply omits Room identity instead of inventing one from live transport.
final class RideRoomIdentityResolver {
  const RideRoomIdentityResolver(this._repository);

  final RoomRepository _repository;

  Future<RideRoomIdentity?> load() async {
    final selected = await _repository.selectedRoomId();
    if (selected == null) return null;

    final saved = await _repository.get(selected);
    if (saved == null || saved.room.archived || !saved.membership.active) {
      return null;
    }

    return RideRoomIdentity.fromSavedRoom(saved);
  }
}
