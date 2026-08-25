import '../entity/room.dart';

abstract interface class RoomRepository {
  Future<List<SavedRoom>> list({bool includeArchived = false});

  Future<SavedRoom?> get(RoomId id);

  Future<SavedRoom> create({
    required String name,
    required String localDisplayName,
  });

  Future<SavedRoom> rename(RoomId id, String name);

  Future<SavedRoom> setArchived(RoomId id, bool archived);

  /// Leaves durable membership without deleting the saved room record.
  Future<SavedRoom> leave(RoomId id);

  Future<void> delete(RoomId id);

  Future<RoomId?> selectedRoomId();

  /// Explicit current-room selection. Null means no room selected.
  Future<void> select(RoomId? id);
}
