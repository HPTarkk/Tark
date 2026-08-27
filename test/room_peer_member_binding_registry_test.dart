import 'package:flutter_test/flutter_test.dart';
import 'package:tark/feature/room/domain/entity/room.dart';
import 'package:tark/feature/room/domain/service/room_peer_member_binding_registry.dart';

void main() {
  RoomMemberId member(String value) => RoomMemberId(value);

  test('binds only admitted members for current attachment', () {
    final registry = RoomPeerMemberBindingRegistry(
      members: [member('me'), member('peer-a')],
    );

    expect(
      registry.bind(
        peerKey: 'transport-peer-a',
        memberId: member('peer-a'),
        attachmentGeneration: 4,
      ),
      isTrue,
    );
    expect(
      registry.resolve('transport-peer-a', attachmentGeneration: 4),
      member('peer-a'),
    );
    expect(
      registry.bind(
        peerKey: 'attacker',
        memberId: member('not-in-room'),
        attachmentGeneration: 4,
      ),
      isFalse,
    );
    expect(registry.resolve('attacker', attachmentGeneration: 4), isNull);
  });

  test('older attachment cannot overwrite a newer peer binding', () {
    final registry = RoomPeerMemberBindingRegistry(
      members: [member('peer-a'), member('peer-b')],
    );

    expect(
      registry.bind(
        peerKey: 'transport-peer',
        memberId: member('peer-a'),
        attachmentGeneration: 8,
      ),
      isTrue,
    );
    expect(
      registry.bind(
        peerKey: 'transport-peer',
        memberId: member('peer-b'),
        attachmentGeneration: 7,
      ),
      isFalse,
    );
    expect(
      registry.resolve('transport-peer', attachmentGeneration: 8),
      member('peer-a'),
    );
  });

  test('one member cannot retain two peer bindings in same/new generation', () {
    final registry = RoomPeerMemberBindingRegistry(members: [member('peer-a')]);

    registry.bind(
      peerKey: 'old-route',
      memberId: member('peer-a'),
      attachmentGeneration: 2,
    );
    expect(
      registry.bind(
        peerKey: 'new-route',
        memberId: member('peer-a'),
        attachmentGeneration: 3,
      ),
      isTrue,
    );

    expect(registry.resolve('old-route', attachmentGeneration: 2), isNull);
    expect(
      registry.resolve('new-route', attachmentGeneration: 3),
      member('peer-a'),
    );
    expect(registry.length, 1);
  });

  test('attachment replacement invalidates stale transport identity', () {
    final registry = RoomPeerMemberBindingRegistry(members: [member('peer-a')]);
    registry.bind(
      peerKey: 'route-a',
      memberId: member('peer-a'),
      attachmentGeneration: 5,
    );

    registry.replaceAttachment(6);

    expect(registry.resolve('route-a', attachmentGeneration: 5), isNull);
    expect(registry.length, 0);
    expect(
      registry.bind(
        peerKey: 'route-b',
        memberId: member('peer-a'),
        attachmentGeneration: 6,
      ),
      isTrue,
    );
  });

  test('delayed old callback cannot create a new stale binding', () {
    final registry = RoomPeerMemberBindingRegistry(members: [member('peer-a')]);
    registry.replaceAttachment(9);

    expect(
      registry.bind(
        peerKey: 'late-old-route',
        memberId: member('peer-a'),
        attachmentGeneration: 8,
      ),
      isFalse,
    );
    expect(
      registry.resolve('late-old-route', attachmentGeneration: 8),
      isNull,
    );
    expect(registry.length, 0);
  });

  test('membership removal immediately invalidates peer binding', () {
    final registry = RoomPeerMemberBindingRegistry(
      members: [member('peer-a'), member('peer-b')],
    );
    registry.bind(
      peerKey: 'route-a',
      memberId: member('peer-a'),
      attachmentGeneration: 1,
    );
    registry.bind(
      peerKey: 'route-b',
      memberId: member('peer-b'),
      attachmentGeneration: 1,
    );

    registry.replaceMembers([member('peer-b')]);

    expect(registry.resolve('route-a', attachmentGeneration: 1), isNull);
    expect(
      registry.resolve('route-b', attachmentGeneration: 1),
      member('peer-b'),
    );
    expect(
      registry.bind(
        peerKey: 'route-a2',
        memberId: member('peer-a'),
        attachmentGeneration: 1,
      ),
      isFalse,
    );
  });

  test('dispose clears state and rejects later use', () {
    final registry = RoomPeerMemberBindingRegistry(members: [member('peer-a')]);
    registry.bind(
      peerKey: 'route-a',
      memberId: member('peer-a'),
      attachmentGeneration: 1,
    );

    registry.dispose();
    registry.dispose();

    expect(
      () => registry.resolve('route-a', attachmentGeneration: 1),
      throwsStateError,
    );
  });
}
