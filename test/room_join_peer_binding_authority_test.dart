import 'package:flutter_test/flutter_test.dart';
import 'package:tark/feature/room/domain/entity/room.dart';
import 'package:tark/feature/room/domain/service/room_invite_join_exchange.dart';
import 'package:tark/feature/room/domain/service/room_join_peer_binding_authority.dart';
import 'package:tark/feature/room/domain/service/room_peer_member_binding_registry.dart';

void main() {
  const roomId = RoomId('aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa');
  const memberId = RoomMemberId('bbbbbbbbbbbbbbbbbbbbbbbb');
  const requestId = 'cccccccccccccccccccccccccccccccc';
  final at = DateTime.utc(2026, 8, 27, 4, 30);

  late RoomPeerMemberBindingRegistry bindings;
  late RoomJoinPeerBindingAuthority authority;

  setUp(() {
    bindings = RoomPeerMemberBindingRegistry(members: const [memberId]);
    authority = RoomJoinPeerBindingAuthority(
      roomId: roomId,
      bindings: bindings,
    );
  });

  tearDown(() {
    authority.dispose();
    bindings.dispose();
  });

  RoomInviteJoinResponse accepted({
    String id = requestId,
    RoomId acceptedRoom = roomId,
    RoomMemberId acceptedMember = memberId,
  }) => RoomInviteJoinResponse.accepted(
    requestId: id,
    roomId: acceptedRoom,
    memberId: acceptedMember,
  );

  test('observed route binds only after exact verified accepted response', () {
    expect(
      authority.observeRequest(
        requestId: requestId,
        peerKey: 'route-a',
        attachmentGeneration: 4,
        at: at,
      ),
      isTrue,
    );
    expect(bindings.resolve('route-a', attachmentGeneration: 4), isNull);

    expect(
      authority.bindAcceptedResponse(
        response: accepted(),
        attachmentGeneration: 4,
        at: at.add(const Duration(seconds: 1)),
      ),
      isTrue,
    );
    expect(bindings.resolve('route-a', attachmentGeneration: 4), memberId);
    expect(authority.pendingCount, 0);
  });

  test('same-generation replay from another route cannot steal binding', () {
    expect(
      authority.observeRequest(
        requestId: requestId,
        peerKey: 'route-original',
        attachmentGeneration: 4,
        at: at,
      ),
      isTrue,
    );
    expect(
      authority.observeRequest(
        requestId: requestId,
        peerKey: 'route-replay',
        attachmentGeneration: 4,
        at: at.add(const Duration(milliseconds: 100)),
      ),
      isFalse,
    );

    expect(
      authority.bindAcceptedResponse(
        response: accepted(),
        attachmentGeneration: 4,
        at: at.add(const Duration(seconds: 1)),
      ),
      isTrue,
    );
    expect(
      bindings.resolve('route-original', attachmentGeneration: 4),
      memberId,
    );
    expect(
      bindings.resolve('route-replay', attachmentGeneration: 4),
      isNull,
    );
  });

  test('self-claimed or unrelated accepted response cannot steal route', () {
    expect(
      authority.observeRequest(
        requestId: requestId,
        peerKey: 'route-a',
        attachmentGeneration: 2,
        at: at,
      ),
      isTrue,
    );

    const otherRequest = 'dddddddddddddddddddddddddddddddd';
    expect(
      authority.bindAcceptedResponse(
        response: accepted(id: otherRequest),
        attachmentGeneration: 2,
        at: at,
      ),
      isFalse,
    );
    expect(bindings.resolve('route-a', attachmentGeneration: 2), isNull);
    expect(authority.pendingCount, 1);
  });

  test('cross-room response fails closed', () {
    expect(
      authority.observeRequest(
        requestId: requestId,
        peerKey: 'route-a',
        attachmentGeneration: 1,
        at: at,
      ),
      isTrue,
    );

    expect(
      authority.bindAcceptedResponse(
        response: accepted(
          acceptedRoom: const RoomId('eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee'),
        ),
        attachmentGeneration: 1,
        at: at,
      ),
      isFalse,
    );
    expect(bindings.resolve('route-a', attachmentGeneration: 1), isNull);
  });

  test('unadmitted member cannot become a binding', () {
    expect(
      authority.observeRequest(
        requestId: requestId,
        peerKey: 'route-a',
        attachmentGeneration: 3,
        at: at,
      ),
      isTrue,
    );

    expect(
      authority.bindAcceptedResponse(
        response: accepted(
          acceptedMember: const RoomMemberId('ffffffffffffffffffffffff'),
        ),
        attachmentGeneration: 3,
        at: at,
      ),
      isFalse,
    );
    expect(bindings.resolve('route-a', attachmentGeneration: 3), isNull);
  });

  test('expired request evidence cannot authorize a later packet route', () {
    expect(
      authority.observeRequest(
        requestId: requestId,
        peerKey: 'route-a',
        attachmentGeneration: 5,
        at: at,
      ),
      isTrue,
    );

    expect(
      authority.bindAcceptedResponse(
        response: accepted(),
        attachmentGeneration: 5,
        at: at.add(const Duration(seconds: 31)),
      ),
      isFalse,
    );
    expect(authority.pendingCount, 0);
    expect(bindings.resolve('route-a', attachmentGeneration: 5), isNull);
  });

  test('transport replacement rejects stale request and route evidence', () {
    expect(
      authority.observeRequest(
        requestId: requestId,
        peerKey: 'old-route',
        attachmentGeneration: 7,
        at: at,
      ),
      isTrue,
    );
    authority.replaceAttachment(8);

    expect(
      authority.bindAcceptedResponse(
        response: accepted(),
        attachmentGeneration: 7,
        at: at.add(const Duration(seconds: 1)),
      ),
      isFalse,
    );
    expect(bindings.resolve('old-route', attachmentGeneration: 7), isNull);
  });

  test('pending request evidence is bounded by oldest observation', () {
    final bounded = RoomJoinPeerBindingAuthority(
      roomId: roomId,
      bindings: bindings,
      maxPending: 2,
    );
    addTearDown(bounded.dispose);

    for (var i = 0; i < 3; i++) {
      final id = i.toRadixString(16).padLeft(32, '0');
      expect(
        bounded.observeRequest(
          requestId: id,
          peerKey: 'route-$i',
          attachmentGeneration: 1,
          at: at.add(Duration(seconds: i)),
        ),
        isTrue,
      );
    }

    expect(bounded.pendingCount, 2);
    expect(
      bounded.bindAcceptedResponse(
        response: accepted(id: '00000000000000000000000000000000'),
        attachmentGeneration: 1,
        at: at.add(const Duration(seconds: 3)),
      ),
      isFalse,
    );
  });
}
