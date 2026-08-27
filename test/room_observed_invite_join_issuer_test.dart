import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:tark/feature/room/data/repository/shared_preferences_room_repository.dart';
import 'package:tark/feature/room/domain/entity/room_invitation.dart';
import 'package:tark/feature/room/domain/service/room_invite_acceptance_coordinator.dart';
import 'package:tark/feature/room/domain/service/room_invite_join_exchange.dart';
import 'package:tark/feature/room/domain/service/room_join_peer_binding_authority.dart';
import 'package:tark/feature/room/domain/service/room_observed_invite_join_issuer.dart';
import 'package:tark/feature/room/domain/service/room_peer_member_binding_registry.dart';

void main() {
  final now = DateTime.utc(2026, 8, 27, 6);
  const requestId = 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';

  late SharedPreferencesRoomRepository repository;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    repository = SharedPreferencesRoomRepository();
  });

  Future<({
    RoomInvitation invite,
    RoomPeerMemberBindingRegistry bindings,
    RoomJoinPeerBindingAuthority authority,
    RoomObservedInviteJoinIssuer issuer,
  })> setup() async {
    final room = await repository.create(
      name: 'Morning ride',
      localDisplayName: 'Owner',
    );
    final invite = await repository.issueInvite(
      room.room.id,
      kind: RoomInvitationKind.trustedMembership,
      now: now,
      ttl: const Duration(hours: 1),
    );
    final bindings = RoomPeerMemberBindingRegistry(
      members: room.room.members.map((member) => member.id),
    );
    final authority = RoomJoinPeerBindingAuthority(
      roomId: room.room.id,
      bindings: bindings,
    );
    final exchange = RoomInviteJoinExchange(
      acceptance: RoomInviteAcceptanceCoordinator(repository),
    );
    final issuer = RoomObservedInviteJoinIssuer(
      exchange: exchange,
      bindingAuthority: authority,
    );
    addTearDown(authority.dispose);
    addTearDown(bindings.dispose);
    return (
      invite: invite,
      bindings: bindings,
      authority: authority,
      issuer: issuer,
    );
  }

  RoomInviteJoinRequest request(RoomInvitation invite) => RoomInviteJoinRequest(
    requestId: requestId,
    invitation: invite,
    displayName: 'Rider two',
  );

  test('verified join binds carrier-observed route to admitted member', () async {
    final value = await setup();

    final encoded = await value.issuer.handle(
      encodedRequest: request(value.invite).encode(),
      peerKey: 'device-route-a',
      attachmentGeneration: 3,
      now: now.add(const Duration(minutes: 1)),
    );
    final response = RoomInviteJoinResponse.decode(encoded);

    expect(response.status, RoomInviteJoinResponseStatus.accepted);
    expect(response.memberId, isNotNull);
    expect(
      value.bindings.resolve('device-route-a', attachmentGeneration: 3),
      response.memberId,
    );
    expect(value.authority.pendingCount, 0);
  });

  test('forged invite cannot authorize observed route', () async {
    final value = await setup();
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

    final encoded = await value.issuer.handle(
      encodedRequest: request(forged).encode(),
      peerKey: 'attacker-route',
      attachmentGeneration: 2,
      now: now.add(const Duration(minutes: 1)),
    );
    final response = RoomInviteJoinResponse.decode(encoded);

    expect(response.status, RoomInviteJoinResponseStatus.rejected);
    expect(
      value.bindings.resolve('attacker-route', attachmentGeneration: 2),
      isNull,
    );
  });

  test('stale attachment observation cannot bind accepted member', () async {
    final value = await setup();
    value.authority.replaceAttachment(5);

    final encoded = await value.issuer.handle(
      encodedRequest: request(value.invite).encode(),
      peerKey: 'stale-route',
      attachmentGeneration: 4,
      now: now.add(const Duration(minutes: 1)),
    );
    final response = RoomInviteJoinResponse.decode(encoded);

    expect(response.status, RoomInviteJoinResponseStatus.accepted);
    expect(
      value.bindings.resolve('stale-route', attachmentGeneration: 4),
      isNull,
    );
  });

  test('same request replay from another route cannot steal first route', () async {
    final value = await setup();
    final encodedRequest = request(value.invite).encode();

    final first = await value.issuer.handle(
      encodedRequest: encodedRequest,
      peerKey: 'first-route',
      attachmentGeneration: 1,
      now: now.add(const Duration(minutes: 1)),
    );
    final firstResponse = RoomInviteJoinResponse.decode(first);
    expect(firstResponse.status, RoomInviteJoinResponseStatus.accepted);

    final second = await value.issuer.handle(
      encodedRequest: encodedRequest,
      peerKey: 'replay-route',
      attachmentGeneration: 1,
      now: now.add(const Duration(minutes: 2)),
    );
    expect(RoomInviteJoinResponse.decode(second).status, isNot(RoomInviteJoinResponseStatus.accepted));
    expect(
      value.bindings.resolve('first-route', attachmentGeneration: 1),
      firstResponse.memberId,
    );
    expect(
      value.bindings.resolve('replay-route', attachmentGeneration: 1),
      isNull,
    );
  });
}
