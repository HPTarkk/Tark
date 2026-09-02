import '../domain/entity/room.dart';

/// What to call a member on screen.
///
/// A seat opened by an invite has to exist before it can know who will take it,
/// so the host's own sheet writes a placeholder into it — "Open seat", named
/// that way in R7 precisely so an empty seat never reads like a person. That
/// placeholder is durable, and once the seat is confirmed it is a lie: the row
/// is occupied, and it is claiming to be free.
///
/// Confirmation cannot simply erase it. `_decodeMember` treats a nameless
/// member as a corrupt record and `_decodeRoom` answers a corrupt record by
/// dropping the **whole room**, so writing an empty name would make a rider's
/// room vanish — and would do it on any older build reading a newer record,
/// which is exactly the population that sideloads APKs here. So the placeholder
/// stays in storage and is unwritten at the point of display instead.
///
/// Both languages are checked, not just the current one. The stored string is
/// frozen in whichever locale the host was using when they opened the seat, and
/// the person reading the roster may not be in that locale.
String roomMemberDisplayName(
  RoomMember member, {
  required bool fa,
  required String unnamed,
}) {
  final name = member.displayName.trim();
  if (name.isEmpty || _heldSeatPlaceholders.contains(name)) {
    // A seat nobody has claimed still says so — that is the placeholder doing
    // its job. It is only wrong once the seat is occupied.
    return member.pending ? heldSeatNameFor(fa: fa) : unnamed;
  }
  return name;
}

/// What an unclaimed seat is called.
///
/// The one writer is the invite path in `room_people_sheet.dart`, which stores
/// it as the new member's display name.
String heldSeatNameFor({required bool fa}) => fa ? 'جای خالی' : 'Open seat';

/// Every language's version of [heldSeatNameFor], because the stored one is frozen
/// in the host's locale at the moment the seat was opened.
const _heldSeatPlaceholders = {'Open seat', 'جای خالی'};
