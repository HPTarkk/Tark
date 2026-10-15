import 'package:flutter_test/flutter_test.dart';
import 'package:tark/feature/room/domain/entity/room.dart';
import 'package:tark/feature/room/domain/service/room_bluetooth_rendezvous.dart';

/// Two phones of one Room find each other over Bluetooth without a code:
/// each works out on its own who listens and what for, and must land on the
/// same answer.
void main() {
  const room = RoomId('room-1');
  const a = RoomMemberId('aaa');
  const b = RoomMemberId('bbb');
  final day = DateTime.utc(2026, 10, 15, 9);

  test('both phones pick the same listener', () {
    expect(RoomBluetoothRendezvous.listenerOf(a, b), a);
    expect(RoomBluetoothRendezvous.listenerOf(b, a), a);
  });

  test('both phones derive the same token', () async {
    final one = await RoomBluetoothRendezvous.linkFor(
      room: room,
      listener: a,
      now: day,
    );
    final two = await RoomBluetoothRendezvous.linkFor(
      room: room,
      listener: a,
      now: day.add(const Duration(hours: 10)),
    );
    expect(one.token, two.token);
    expect(one.token, matches(RegExp(r'^[0-9a-f]{32}$')));
  });

  test('another Room, listener or day is another token', () async {
    final base = await RoomBluetoothRendezvous.linkFor(
      room: room,
      listener: a,
      now: day,
    );
    for (final other in [
      RoomBluetoothRendezvous.linkFor(
        room: const RoomId('room-2'),
        listener: a,
        now: day,
      ),
      RoomBluetoothRendezvous.linkFor(room: room, listener: b, now: day),
      RoomBluetoothRendezvous.linkFor(
        room: room,
        listener: a,
        now: day.add(const Duration(days: 1)),
      ),
    ]) {
      expect((await other).token, isNot(base.token));
    }
  });

  test('the token does not carry the Room id', () async {
    final link = await RoomBluetoothRendezvous.linkFor(
      room: const RoomId('abcdef0123456789'),
      listener: a,
      now: day,
    );
    expect(link.token.contains('abcdef0123456789'), isFalse);
  });
}
