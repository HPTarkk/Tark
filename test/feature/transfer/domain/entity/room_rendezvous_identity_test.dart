import 'package:flutter_test/flutter_test.dart';
import 'package:tark/feature/transfer/domain/entity/room_rendezvous_identity.dart';

void main() {
  test('same invitation derives the same compact BLE service data', () async {
    const token = '0123456789abcdef0123456789abcdef';

    final first = await RoomRendezvousIdentity.derive(token);
    final second = await RoomRendezvousIdentity.derive(token.toUpperCase());

    expect(first.serviceData, second.serviceData);
    expect(first.correlation, second.correlation);
    expect(first.serviceData, hasLength(RoomRendezvousIdentity.serviceDataLength));
    expect(first.serviceData.first, RoomRendezvousIdentity.protocolVersion);
    expect(first.correlation, matches(RegExp(r'^[0-9a-f]{8}$')));
  });

  test('a different invitation cannot match the QR-bound BLE identity', () async {
    final one = await RoomRendezvousIdentity.derive(
      '0123456789abcdef0123456789abcdef',
    );
    final two = await RoomRendezvousIdentity.derive(
      'fedcba9876543210fedcba9876543210',
    );

    expect(two.serviceData, isNot(one.serviceData));
    expect(two.correlation, isNot(one.correlation));
  });

  test('invalid rendezvous token fails closed', () {
    expect(
      () => RoomRendezvousIdentity.derive('not-an-invitation-id'),
      throwsFormatException,
    );
  });
}
