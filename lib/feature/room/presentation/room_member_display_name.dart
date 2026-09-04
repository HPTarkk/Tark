import '../domain/entity/held_seat_name.dart';
import '../domain/entity/room.dart';

export '../domain/entity/held_seat_name.dart' show heldSeatNameFor;

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
/// R27b closed the other half: when the seat's owner is on the air, their own
/// phone signs its name beside the route proof and this one writes it over the
/// placeholder, so the row says who is in it rather than "Room member". This
/// remains the answer for every seat that has not reached that point.
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
  if (name.isEmpty || isHeldSeatPlaceholder(name)) {
    // A seat nobody has claimed still says so — that is the placeholder doing
    // its job. It is only wrong once the seat is occupied.
    return member.pending ? heldSeatNameFor(fa: fa) : unnamed;
  }
  return name;
}
