import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:tark/feature/room/data/repository/shared_preferences_room_repository.dart';
import 'package:tark/feature/room/domain/entity/room.dart';
import 'package:tark/feature/room/domain/entity/room_accepted_join_snapshot.dart';
import 'package:tark/feature/room/domain/entity/room_invitation.dart';
import 'package:tark/feature/room/domain/service/room_invite_join_exchange.dart';
import 'package:tark/feature/room/domain/service/room_invite_join_importer.dart';

void main() {
  late SharedPreferencesRoomRepository repository;
  late RoomInviteJoinImporter importer;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    repository = SharedPreferencesRoomRepository();
    importer = RoomInviteJoinImporter(repository: repository);
  });

  ({RoomInviteJoinRequest request, String response, RoomMemberId memberId})
  acceptedExchange() {
    final now = DateTime.utc(2026, 8, 26, 16);
    const roomId = RoomId('0123456789abcdef0123456789abcdef');
    final invitation = generateRoomInvitation(
      roomId: roomId,
      kind: RoomInvitationKind.trustedMembership,
      now: now,
      ttl: const Duration(hours: 1),
    );
    final memberId = RoomMemberId(invitation.invitationId.substring(0, 24));
    final request = RoomInviteJoinRequest(
      requestId: 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
      invitation: invitation,
      displayName: 'Joined rider',
    );
    final snapshot = RoomAcceptedJoinSnapshot(
      roomId: roomId,
      roomName: 'Night riders',
      roomCreatedAt: now.subtract(const Duration(days: 2)),
      roomUpdatedAt: now,
      members: [
        RoomAcceptedJoinMember(
          memberId: const RoomMemberId('111111111111111111111111'),
          displayName: 'Owner',
          joinedAt: now.subtract(const Duration(days: 2)),
          kind: RoomMemberKind.member,
        ),
        RoomAcceptedJoinMember(
          memberId: memberId,
          displayName: 'Joined rider',
          joinedAt: now,
          kind: RoomMemberKind.member,
        ),
      ],
    );
    final response = RoomInviteJoinResponse.accepted(
      requestId: request.requestId,
      roomId: roomId,
      memberId: memberId,
      snapshot: snapshot,
    ).encode();
    return (request: request, response: response, memberId: memberId);
  }

  test('verified accepted response persists and selects durable Room', () async {
    final value = acceptedExchange();

    final saved = await importer.importAcceptedResponse(
      request: value.request,
      encodedResponse: value.response,
    );
    final reopened = SharedPreferencesRoomRepository();

    expect(saved?.room.name, 'Night riders');
    expect(saved?.membership.localMemberId, value.memberId);
    expect(saved?.room.members, hasLength(2));
    expect(await reopened.selectedRoomId(), value.request.invitation.roomId);
    expect(
      (await reopened.get(value.request.invitation.roomId))
          ?.membership
          .localMemberId,
      value.memberId,
    );
  });

  test('stale duplicate response cannot roll back newer local Room state', () async {
    final value = acceptedExchange();
    await importer.importAcceptedResponse(
      request: value.request,
      encodedResponse: value.response,
    );
    final renamed = await repository.rename(
      value.request.invitation.roomId,
      'Locally newer name',
    );
    await repository.select(null);

    final replayed = await importer.importAcceptedResponse(
      request: value.request,
      encodedResponse: value.response,
    );
    final persisted = await repository.get(value.request.invitation.roomId);

    expect(replayed?.room.name, 'Locally newer name');
    expect(replayed?.room.updatedAt, renamed.room.updatedAt);
    expect(persisted?.room.name, 'Locally newer name');
    expect(await repository.selectedRoomId(), value.request.invitation.roomId);
  });

  test('forged accepted member cannot mutate or select local state', () async {
    final value = acceptedExchange();
    final decoded = RoomInviteJoinResponse.decode(value.response);
    final forged = RoomInviteJoinResponse.accepted(
      requestId: decoded.requestId,
      roomId: decoded.roomId!,
      memberId: const RoomMemberId('ffffffffffffffffffffffff'),
      snapshot: decoded.snapshot,
    ).encode();

    final saved = await importer.importAcceptedResponse(
      request: value.request,
      encodedResponse: forged,
    );

    expect(saved, isNull);
    expect(await repository.list(includeArchived: true), isEmpty);
    expect(await repository.selectedRoomId(), isNull);
  });

  test('legacy acceptance without durable snapshot fails closed', () async {
    final value = acceptedExchange();
    final legacy = RoomInviteJoinResponse.accepted(
      requestId: value.request.requestId,
      roomId: value.request.invitation.roomId,
      memberId: value.memberId,
    ).encode();

    final saved = await importer.importAcceptedResponse(
      request: value.request,
      encodedResponse: legacy,
    );

    expect(saved, isNull);
    expect(await repository.list(includeArchived: true), isEmpty);
    expect(await repository.selectedRoomId(), isNull);
  });
}
