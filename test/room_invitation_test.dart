import 'dart:convert';
import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:tark/feature/room/domain/entity/room.dart';
import 'package:tark/feature/room/domain/entity/room_invitation.dart';
import 'package:tark/feature/room/domain/service/room_invitation_ledger.dart';

void main() {
  final roomId = RoomId.parse('0123456789abcdef0123456789abcdef')!;
  final now = DateTime.utc(2026, 8, 25, 10);

  RoomInvitation invite({
    RoomInvitationKind kind = RoomInvitationKind.trustedMembership,
    Duration ttl = const Duration(hours: 24),
    RoomTransportBootstrap? transport,
  }) => generateRoomInvitation(
    roomId: roomId,
    kind: kind,
    now: now,
    ttl: ttl,
    transportBootstrap: transport,
    random: Random(42),
  );

  test('round trips a versioned high-entropy capability', () {
    final original = invite();
    final parsed = RoomInvitation.decode(original.encode());

    expect(parsed.roomId, roomId);
    expect(parsed.invitationId, hasLength(32));
    expect(parsed.secret, hasLength(64));
    expect(parsed.displayCode, matches(RegExp(r'^\d{6}$')));
    expect(parsed.secret, isNot(parsed.displayCode));
    expect(parsed.kind, RoomInvitationKind.trustedMembership);
    expect(parsed.singleUse, isFalse);
  });

  test('single-ride guest invite is single-use and replay is rejected', () {
    final guest = invite(kind: RoomInvitationKind.singleRideGuest);
    final ledger = RoomInvitationLedger();

    expect(
      ledger.redeem(guest, now.add(const Duration(minutes: 5))),
      RoomInvitationDecision.accepted,
    );
    expect(
      ledger.redeem(guest, now.add(const Duration(minutes: 6))),
      RoomInvitationDecision.replayed,
    );
  });

  test('revocation rejects a reusable membership invite', () {
    final membership = invite();
    final ledger = RoomInvitationLedger()..revoke(membership);

    expect(
      ledger.evaluate(membership, now.add(const Duration(minutes: 1))),
      RoomInvitationDecision.revoked,
    );
  });

  test('expired invite fails closed', () {
    final expiring = invite(ttl: const Duration(minutes: 10));
    final ledger = RoomInvitationLedger();

    expect(
      ledger.evaluate(expiring, now.add(const Duration(minutes: 10))),
      RoomInvitationDecision.expired,
    );
  });

  test('transport bootstrap rotates independently from room identity', () {
    final first = invite(
      transport: const RoomTransportBootstrap(
        kind: 'hotspot',
        payload: {'ssid': 'temporary-a'},
      ),
    );
    final second = invite(
      transport: const RoomTransportBootstrap(
        kind: 'hotspot',
        payload: {'ssid': 'temporary-b'},
      ),
    );

    expect(first.roomId, second.roomId);
    expect(
      first.transportBootstrap!.payload,
      isNot(second.transportBootstrap!.payload),
    );
  });

  test('unsupported version and malformed capability fail closed', () {
    final original = invite();
    final decoded =
        jsonDecode(
              utf8.decode(
                base64Url.decode(base64Url.normalize(original.encode())),
              ),
            )
            as Map<String, dynamic>;
    decoded['v'] = 99;
    final bad = base64Url
        .encode(utf8.encode(jsonEncode(decoded)))
        .replaceAll('=', '');

    expect(() => RoomInvitation.decode(bad), throwsFormatException);
    expect(() => RoomInvitation.decode('not-an-invite'), throwsFormatException);
  });

  test(
    'tampered display code fails parsing and cannot authorize membership',
    () {
      final original = invite();
      final decoded =
          jsonDecode(
                utf8.decode(
                  base64Url.decode(base64Url.normalize(original.encode())),
                ),
              )
              as Map<String, dynamic>;
      decoded['displayCode'] = '000000';
      final bad = base64Url
          .encode(utf8.encode(jsonEncode(decoded)))
          .replaceAll('=', '');

      expect(() => RoomInvitation.decode(bad), throwsFormatException);
    },
  );

  test('ledger state survives persistence without storing bearer secrets', () {
    final guest = invite(kind: RoomInvitationKind.singleRideGuest);
    final membership = invite();
    final ledger = RoomInvitationLedger()
      ..redeem(guest, now.add(const Duration(minutes: 1)))
      ..revoke(membership);

    final state = ledger.encodeState();
    expect(state, isNot(contains(guest.secret)));
    expect(state, isNot(contains(membership.secret)));

    final restored = RoomInvitationLedger.decodeState(state);
    expect(
      restored.evaluate(guest, now.add(const Duration(minutes: 2))),
      RoomInvitationDecision.replayed,
    );
    expect(
      restored.evaluate(membership, now.add(const Duration(minutes: 2))),
      RoomInvitationDecision.revoked,
    );
  });
}
