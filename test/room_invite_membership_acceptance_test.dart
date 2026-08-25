import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:tark/feature/room/data/repository/shared_preferences_room_repository.dart';
import 'package:tark/feature/room/domain/entity/room.dart';
import 'package:tark/feature/room/domain/entity/room_invitation.dart';
import 'package:tark/feature/room/domain/service/room_invitation_ledger.dart';

void main() {
  late SharedPreferencesRoomRepository repository;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    repository = SharedPreferencesRoomRepository();
  });

  Future<({SavedRoom room, RoomInvitation invite, DateTime now})> fixture({
    RoomInvitationKind kind = RoomInvitationKind.trustedMembership,
  }) async {
    final room = await repository.create(
      name: 'Night ride',
      localDisplayName: 'Owner',
    );
    final now = DateTime.utc(2026, 8, 25, 18);
    final invite = generateRoomInvitation(
      roomId: room.room.id,
      kind: kind,
      now: now,
      ttl: const Duration(hours: 1),
    );
    return (room: room, invite: invite, now: now);
  }

  test('verified invite durably adds one stable generic member', () async {
    final value = await fixture();
    final ledger = RoomInvitationLedger()..registerIssued(value.invite);
    final verified = ledger.verifyAndRedeem(
      value.invite,
      value.now.add(const Duration(minutes: 1)),
    );

    expect(verified, isNotNull);
    final accepted = await repository.acceptVerifiedInvite(
      verified!,
      displayName: 'Rider three',
      acceptedAt: value.now.add(const Duration(minutes: 1)),
    );

    expect(accepted.room.id, value.room.room.id);
    expect(accepted.room.members, hasLength(2));
    final joined = accepted.room.members.singleWhere(
      (member) => member.id != value.room.membership.localMemberId,
    );
    expect(joined.id.value, value.invite.invitationId.substring(0, 24));
    expect(joined.displayName, 'Rider three');
    expect(joined.kind, RoomMemberKind.member);

    final persisted = await repository.get(value.room.room.id);
    expect(persisted?.room.members, hasLength(2));
  });

  test(
    'reusing same verified capability is idempotent, not duplicate',
    () async {
      final value = await fixture();
      final ledger = RoomInvitationLedger()..registerIssued(value.invite);
      final verified = ledger.verifyAndRedeem(value.invite, value.now)!;

      await repository.acceptVerifiedInvite(
        verified,
        displayName: 'Rider',
        acceptedAt: value.now,
      );
      final second = await repository.acceptVerifiedInvite(
        verified,
        displayName: 'Rider renamed',
        acceptedAt: value.now.add(const Duration(minutes: 2)),
      );

      expect(second.room.members, hasLength(2));
      expect(
        second.room.members.where(
          (member) =>
              member.id.value == value.invite.invitationId.substring(0, 24),
        ),
        hasLength(1),
      );
    },
  );

  test('forged capability fails closed before repository mutation', () async {
    final value = await fixture();
    final ledger = RoomInvitationLedger()..registerIssued(value.invite);
    final forged = RoomInvitation(
      version: value.invite.version,
      roomId: value.invite.roomId,
      invitationId: value.invite.invitationId,
      secret: List.filled(64, 'f').join(),
      kind: value.invite.kind,
      issuedAt: value.invite.issuedAt,
      expiresAt: value.invite.expiresAt,
      singleUse: value.invite.singleUse,
      displayCode: value.invite.displayCode,
    );

    expect(ledger.verifyAndRedeem(forged, value.now), isNull);
    expect(
      (await repository.get(value.room.room.id))?.room.members,
      hasLength(1),
    );
  });

  test(
    'revoked and expired invites cannot obtain verified capability',
    () async {
      final value = await fixture();
      final revokedLedger = RoomInvitationLedger()
        ..registerIssued(value.invite);
      revokedLedger.revoke(value.invite);
      expect(revokedLedger.verifyAndRedeem(value.invite, value.now), isNull);

      final expiredLedger = RoomInvitationLedger()
        ..registerIssued(value.invite);
      expect(
        expiredLedger.verifyAndRedeem(value.invite, value.invite.expiresAt),
        isNull,
      );
    },
  );

  test('single-use guest is replay protected and stored as guest', () async {
    final value = await fixture(kind: RoomInvitationKind.singleRideGuest);
    final ledger = RoomInvitationLedger()..registerIssued(value.invite);
    final verified = ledger.verifyAndRedeem(value.invite, value.now);

    expect(verified, isNotNull);
    expect(ledger.verifyAndRedeem(value.invite, value.now), isNull);

    final accepted = await repository.acceptVerifiedInvite(
      verified!,
      displayName: 'Guest rider',
      acceptedAt: value.now,
    );
    expect(accepted.room.members.last.kind, RoomMemberKind.guest);
  });
}
