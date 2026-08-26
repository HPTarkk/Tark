import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:tark/feature/room/data/repository/shared_preferences_room_repository.dart';
import 'package:tark/feature/room/domain/entity/room.dart';
import 'package:tark/feature/room/domain/entity/room_invitation.dart';
import 'package:tark/feature/room/domain/service/room_invite_acceptance_coordinator.dart';

void main() {
  late SharedPreferencesRoomRepository repository;
  late RoomInviteAcceptanceCoordinator coordinator;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    repository = SharedPreferencesRoomRepository();
    coordinator = RoomInviteAcceptanceCoordinator(repository);
  });

  Future<({SavedRoom room, RoomInvitation invite, DateTime now})> issued({
    RoomInvitationKind kind = RoomInvitationKind.trustedMembership,
  }) async {
    final room = await repository.create(
      name: 'Night ride',
      localDisplayName: 'Owner',
    );
    final now = DateTime.utc(2026, 8, 26, 12);
    final invite = await repository.issueInvite(
      room.room.id,
      kind: kind,
      now: now,
      ttl: const Duration(hours: 1),
    );
    return (room: room, invite: invite, now: now);
  }

  test('issued capability verifies before durable membership mutation', () async {
    final value = await issued();

    final result = await coordinator.accept(
      invitation: value.invite,
      displayName: 'Rider three',
      now: value.now.add(const Duration(minutes: 1)),
    );

    expect(result.status, RoomInviteAcceptanceStatus.accepted);
    expect(result.room?.room.id, value.room.room.id);
    expect(result.room?.room.members, hasLength(2));
    expect(result.room?.room.members.last.displayName, 'Rider three');
  });

  test('forged bearer secret cannot mutate membership', () async {
    final value = await issued();
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
      transportBootstrap: value.invite.transportBootstrap,
    );

    final result = await coordinator.accept(
      invitation: forged,
      displayName: 'Attacker',
      now: value.now.add(const Duration(minutes: 1)),
    );

    expect(result.status, RoomInviteAcceptanceStatus.rejected);
    expect((await repository.get(value.room.room.id))?.room.members, hasLength(1));
  });

  test('unknown RoomId fails closed without creating a room', () async {
    final now = DateTime.utc(2026, 8, 26, 12);
    final invite = generateRoomInvitation(
      roomId: RoomId.generate(),
      kind: RoomInvitationKind.trustedMembership,
      now: now,
      ttl: const Duration(hours: 1),
    );

    final result = await coordinator.accept(
      invitation: invite,
      displayName: 'Unknown rider',
      now: now,
    );

    expect(result.status, RoomInviteAcceptanceStatus.roomUnavailable);
    expect(await repository.list(includeArchived: true), isEmpty);
  });

  test('single-use guest cannot be accepted twice', () async {
    final value = await issued(kind: RoomInvitationKind.singleRideGuest);

    final first = await coordinator.accept(
      invitation: value.invite,
      displayName: 'Guest',
      now: value.now.add(const Duration(minutes: 1)),
    );
    final second = await coordinator.accept(
      invitation: value.invite,
      displayName: 'Guest again',
      now: value.now.add(const Duration(minutes: 2)),
    );

    expect(first.status, RoomInviteAcceptanceStatus.accepted);
    expect(second.status, RoomInviteAcceptanceStatus.rejected);
    final saved = await repository.get(value.room.room.id);
    expect(saved?.room.members, hasLength(2));
    expect(saved?.room.members.last.kind, RoomMemberKind.guest);
  });
}
