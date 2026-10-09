/// The free tier permits two active Rooms and two people per conversation,
/// irrespective of transport.
/// Callers count confirmed, active members; reserved invite seats don't count.
abstract final class RoomAccessPolicy {
  static const freeMemberLimit = 2;
  static const freeRoomLimit = 2;

  static bool additionalRoomRequiresPremium(int activeRooms) =>
      activeRooms >= freeRoomLimit;

  static bool requiresPremium(int confirmedMembers) =>
      confirmedMembers > freeMemberLimit;

  static bool inviteRequiresPremium(int confirmedMembers) =>
      requiresPremium(confirmedMembers + 1);
}
