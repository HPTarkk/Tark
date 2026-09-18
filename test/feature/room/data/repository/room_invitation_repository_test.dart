import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:tark/feature/room/data/repository/shared_preferences_room_repository.dart';
import 'package:tark/feature/room/domain/entity/room_invitation.dart';

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });

  test('issued invite persists verifier but never raw secret', () async {
    final repository = SharedPreferencesRoomRepository();
    final room = await repository.create(
      name: 'Night ride',
      localDisplayName: 'Rider A',
    );
    final now = DateTime.utc(2026, 8, 26, 1);

    final invite = await repository.issueInvite(
      room.room.id,
      kind: RoomInvitationKind.trustedMembership,
      now: now,
      ttl: const Duration(hours: 12),
      transportBootstrap: const RoomTransportBootstrap(
        kind: 'hotspot',
        payload: {'ssid': 'ephemeral-network', 'password': 'temporary-secret'},
      ),
    );

    final prefs = await SharedPreferences.getInstance();
    final persisted = prefs
        .getKeys()
        .map((key) => prefs.get(key).toString())
        .join();
    expect(persisted, isNot(contains(invite.secret)));
    expect(persisted, isNot(contains('ephemeral-network')));
    expect(persisted, isNot(contains('temporary-secret')));

    final verified = await repository.verifyAndRedeemInvite(
      RoomInvitation.decode(invite.encode()),
      now: now.add(const Duration(minutes: 1)),
    );
    expect(verified, isNotNull);
  });

  test(
    'single-use redemption survives repository recreation and rejects replay',
    () async {
      var repository = SharedPreferencesRoomRepository();
      final room = await repository.create(
        name: 'Guest ride',
        localDisplayName: 'Rider A',
      );
      final now = DateTime.utc(2026, 8, 26, 2);
      final invite = await repository.issueInvite(
        room.room.id,
        kind: RoomInvitationKind.singleRideGuest,
        now: now,
        ttl: const Duration(hours: 2),
      );

      final first = await repository.verifyAndRedeemInvite(
        invite,
        now: now.add(const Duration(minutes: 1)),
      );
      expect(first, isNotNull);

      repository = SharedPreferencesRoomRepository();
      final replay = await repository.verifyAndRedeemInvite(
        invite,
        now: now.add(const Duration(minutes: 2)),
      );
      expect(replay, isNull);
    },
  );

  test('revocation survives repository recreation and fails closed', () async {
    var repository = SharedPreferencesRoomRepository();
    final room = await repository.create(
      name: 'Trusted riders',
      localDisplayName: 'Rider A',
    );
    final now = DateTime.utc(2026, 8, 26, 3);
    final invite = await repository.issueInvite(
      room.room.id,
      kind: RoomInvitationKind.trustedMembership,
      now: now,
      ttl: const Duration(days: 1),
    );

    await repository.revokeInvite(invite);
    repository = SharedPreferencesRoomRepository();

    final verified = await repository.verifyAndRedeemInvite(
      invite,
      now: now.add(const Duration(minutes: 5)),
    );
    expect(verified, isNull);
  });

  test('expired and forged capabilities cannot become verified', () async {
    final repository = SharedPreferencesRoomRepository();
    final room = await repository.create(
      name: 'Morning ride',
      localDisplayName: 'Rider A',
    );
    final now = DateTime.utc(2026, 8, 26, 4);
    final invite = await repository.issueInvite(
      room.room.id,
      kind: RoomInvitationKind.trustedMembership,
      now: now,
      ttl: const Duration(minutes: 10),
    );

    expect(
      await repository.verifyAndRedeemInvite(
        invite,
        now: now.add(const Duration(minutes: 10)),
      ),
      isNull,
    );

    final forged = RoomInvitation(
      version: invite.version,
      roomId: invite.roomId,
      invitationId: invite.invitationId,
      secret: List.filled(64, '0').join(),
      kind: invite.kind,
      issuedAt: invite.issuedAt,
      expiresAt: invite.expiresAt,
      singleUse: invite.singleUse,
      displayCode: invite.displayCode,
      transportBootstrap: invite.transportBootstrap,
    );
    expect(
      await repository.verifyAndRedeemInvite(
        forged,
        now: now.add(const Duration(minutes: 1)),
      ),
      isNull,
    );
  });

  test('deleting a room removes its invitation verifier ledger', () async {
    final repository = SharedPreferencesRoomRepository();
    final room = await repository.create(
      name: 'Temporary room',
      localDisplayName: 'Rider A',
    );
    final invite = await repository.issueInvite(
      room.room.id,
      kind: RoomInvitationKind.trustedMembership,
      now: DateTime.utc(2026, 8, 26, 5),
      ttl: const Duration(hours: 1),
    );
    final prefs = await SharedPreferences.getInstance();
    expect(
      prefs.getKeys().any(
        (key) => key.contains('invites.${room.room.id.value}'),
      ),
      isTrue,
    );

    await repository.delete(room.room.id);
    expect(
      prefs.getKeys().any(
        (key) => key.contains('invites.${room.room.id.value}'),
      ),
      isFalse,
    );
    final persisted = prefs
        .getKeys()
        .map((key) => prefs.get(key).toString())
        .join();
    expect(persisted, isNot(contains(invite.secret)));
  });
}
