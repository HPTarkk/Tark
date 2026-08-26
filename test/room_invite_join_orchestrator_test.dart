import 'dart:async';
import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:tark/feature/room/domain/entity/room.dart';
import 'package:tark/feature/room/domain/entity/room_accepted_join_snapshot.dart';
import 'package:tark/feature/room/domain/entity/room_invitation.dart';
import 'package:tark/feature/room/domain/service/room_invite_join_exchange.dart';
import 'package:tark/feature/room/domain/service/room_invite_join_orchestrator.dart';

void main() {
  final now = DateTime.utc(2026, 8, 26, 18);

  RoomInvitation invitation() => generateRoomInvitation(
    roomId: const RoomId('11111111111111111111111111111111'),
    kind: RoomInvitationKind.trustedMembership,
    now: now,
    ttl: const Duration(hours: 1),
    random: Random(7),
  );

  RoomInviteJoinResponse accepted(RoomInviteJoinRequest request) {
    final memberId = RoomMemberId(
      request.invitation.invitationId.substring(0, 24),
    );
    final snapshot = RoomAcceptedJoinSnapshot(
      roomId: request.invitation.roomId,
      roomName: 'Night ride',
      roomCreatedAt: now.subtract(const Duration(days: 1)),
      roomUpdatedAt: now,
      members: [
        RoomAcceptedJoinMember(
          memberId: const RoomMemberId('aaaaaaaaaaaaaaaaaaaaaaaa'),
          displayName: 'Owner',
          joinedAt: now.subtract(const Duration(days: 1)),
          kind: RoomMemberKind.member,
        ),
        RoomAcceptedJoinMember(
          memberId: memberId,
          displayName: request.displayName,
          joinedAt: now,
          kind: RoomMemberKind.member,
        ),
      ],
    );
    return RoomInviteJoinResponse.accepted(
      requestId: request.requestId,
      roomId: request.invitation.roomId,
      memberId: memberId,
      snapshot: snapshot,
    );
  }

  test('correlated accepted carrier response yields verified grant', () async {
    final subject = RoomInviteJoinOrchestrator(random: Random(1));
    final invite = invitation();
    final result = await subject.join(
      invitation: invite,
      displayName: 'Rider three',
      requestId: '0123456789abcdef0123456789abcdef',
      carrier: _Carrier((encoded) async {
        final request = RoomInviteJoinRequest.decode(encoded);
        return accepted(request).encode();
      }),
    );

    expect(result.status, RoomInviteJoinAttemptStatus.accepted);
    expect(result.grant?.roomId, invite.roomId);
    expect(result.grant?.memberId.value, invite.invitationId.substring(0, 24));
  });

  test('cross-request response fails closed', () async {
    final subject = RoomInviteJoinOrchestrator(random: Random(1));
    final result = await subject.join(
      invitation: invitation(),
      displayName: 'Rider three',
      requestId: '0123456789abcdef0123456789abcdef',
      carrier: _Carrier((encoded) async {
        final request = RoomInviteJoinRequest.decode(encoded);
        final response = accepted(request);
        return RoomInviteJoinResponse.accepted(
          requestId: 'ffffffffffffffffffffffffffffffff',
          roomId: response.roomId!,
          memberId: response.memberId!,
          snapshot: response.snapshot,
        ).encode();
      }),
    );

    expect(result.status, RoomInviteJoinAttemptStatus.invalidResponse);
    expect(result.grant, isNull);
  });

  test('correlated rejection remains a rejection', () async {
    final subject = RoomInviteJoinOrchestrator(random: Random(1));
    final result = await subject.join(
      invitation: invitation(),
      displayName: 'Rider three',
      requestId: '0123456789abcdef0123456789abcdef',
      carrier: _Carrier((encoded) async {
        final request = RoomInviteJoinRequest.decode(encoded);
        return RoomInviteJoinResponse.rejected(
          requestId: request.requestId,
        ).encode();
      }),
    );

    expect(result.status, RoomInviteJoinAttemptStatus.rejected);
  });

  test('cancel makes delayed accepted response harmless', () async {
    final subject = RoomInviteJoinOrchestrator(random: Random(1));
    final pending = Completer<String>();
    final future = subject.join(
      invitation: invitation(),
      displayName: 'Rider three',
      requestId: '0123456789abcdef0123456789abcdef',
      carrier: _Carrier((_) => pending.future),
    );

    subject.cancel();
    final request = RoomInviteJoinRequest(
      requestId: '0123456789abcdef0123456789abcdef',
      invitation: invitation(),
      displayName: 'Rider three',
    );
    pending.complete(accepted(request).encode());

    final result = await future;
    expect(result.status, RoomInviteJoinAttemptStatus.cancelled);
    expect(result.grant, isNull);
  });

  test('carrier exception is an explicit transport failure', () async {
    final subject = RoomInviteJoinOrchestrator(random: Random(1));
    final result = await subject.join(
      invitation: invitation(),
      displayName: 'Rider three',
      requestId: '0123456789abcdef0123456789abcdef',
      carrier: _Carrier((_) => throw StateError('link lost')),
    );

    expect(result.status, RoomInviteJoinAttemptStatus.transportFailure);
  });

  test('starting a newer attempt invalidates delayed older response', () async {
    final subject = RoomInviteJoinOrchestrator(random: Random(1));
    final firstPending = Completer<String>();
    final first = subject.join(
      invitation: invitation(),
      displayName: 'First',
      requestId: '11111111111111111111111111111111',
      carrier: _Carrier((_) => firstPending.future),
    );

    final second = await subject.join(
      invitation: invitation(),
      displayName: 'Second',
      requestId: '22222222222222222222222222222222',
      carrier: _Carrier((encoded) async {
        final request = RoomInviteJoinRequest.decode(encoded);
        return accepted(request).encode();
      }),
    );
    expect(second.status, RoomInviteJoinAttemptStatus.accepted);

    final oldRequest = RoomInviteJoinRequest(
      requestId: '11111111111111111111111111111111',
      invitation: invitation(),
      displayName: 'First',
    );
    firstPending.complete(accepted(oldRequest).encode());
    final stale = await first;
    expect(stale.status, RoomInviteJoinAttemptStatus.cancelled);
  });
}

final class _Carrier implements RoomInviteJoinCarrier {
  const _Carrier(this.handler);

  final Future<String> Function(String encodedRequest) handler;

  @override
  Future<String> exchange(String encodedRequest) => handler(encodedRequest);
}
