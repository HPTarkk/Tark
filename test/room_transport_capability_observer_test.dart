import 'package:flutter_test/flutter_test.dart';
import 'package:tark/feature/room/domain/entity/room.dart';
import 'package:tark/feature/room/domain/service/room_peer_member_binding_registry.dart';
import 'package:tark/feature/room/domain/service/room_transport_candidate_registry.dart';
import 'package:tark/feature/room/domain/service/room_transport_capability_observer.dart';

void main() {
  RoomMemberId member(String value) => RoomMemberId(value);

  RoomTransportCapabilityObserver observer({
    required RoomPeerMemberBindingRegistry bindings,
    required RoomTransportCandidateRegistry candidates,
  }) => RoomTransportCapabilityObserver(
    bindings: bindings,
    candidates: candidates,
  );

  test('unknown transport peer cannot inject planner capability', () {
    final bindings = RoomPeerMemberBindingRegistry(members: [member('peer-a')]);
    final candidates = RoomTransportCandidateRegistry();
    final subject = observer(bindings: bindings, candidates: candidates);
    final now = DateTime.utc(2026, 8, 26, 12);

    expect(
      subject.observePeer(
        peerKey: 'unbound-peer',
        canHostHotspot: true,
        bluetoothSupported: true,
        backgroundReady: true,
        batteryPercent: 100,
        at: now,
        attachmentGeneration: 3,
      ),
      isFalse,
    );
    expect(candidates.snapshot(now: now, attachmentGeneration: 3), isEmpty);
  });

  test('bound peer capability is attributed to durable member', () {
    final bindings = RoomPeerMemberBindingRegistry(members: [member('peer-a')]);
    final candidates = RoomTransportCandidateRegistry();
    final subject = observer(bindings: bindings, candidates: candidates);
    final now = DateTime.utc(2026, 8, 26, 12);
    bindings.bind(
      peerKey: 'route-a',
      memberId: member('peer-a'),
      attachmentGeneration: 4,
    );

    expect(
      subject.observePeer(
        peerKey: 'route-a',
        canHostHotspot: true,
        bluetoothSupported: false,
        backgroundReady: true,
        batteryPercent: 71,
        at: now,
        attachmentGeneration: 4,
        prefersHotspotHost: true,
      ),
      isTrue,
    );

    final snapshot = candidates.snapshot(now: now, attachmentGeneration: 4);
    expect(snapshot, hasLength(1));
    expect(snapshot.single.memberId, member('peer-a'));
    expect(snapshot.single.canHostHotspot, isTrue);
    expect(snapshot.single.bluetoothSupported, isFalse);
    expect(snapshot.single.backgroundReady, isTrue);
    expect(snapshot.single.batteryPercent, 71);
    expect(snapshot.single.prefersHotspotHost, isTrue);
  });

  test('stale generation cannot reuse a newer peer binding', () {
    final bindings = RoomPeerMemberBindingRegistry(members: [member('peer-a')]);
    final candidates = RoomTransportCandidateRegistry();
    final subject = observer(bindings: bindings, candidates: candidates);
    final now = DateTime.utc(2026, 8, 26, 12);
    bindings.bind(
      peerKey: 'route-a',
      memberId: member('peer-a'),
      attachmentGeneration: 8,
    );

    expect(
      subject.observePeer(
        peerKey: 'route-a',
        canHostHotspot: true,
        bluetoothSupported: true,
        backgroundReady: true,
        batteryPercent: 50,
        at: now,
        attachmentGeneration: 7,
      ),
      isFalse,
    );
    expect(candidates.snapshot(now: now, attachmentGeneration: 7), isEmpty);
  });

  test(
    'attachment replacement clears old identity and capability evidence',
    () {
      final bindings = RoomPeerMemberBindingRegistry(
        members: [member('peer-a')],
      );
      final candidates = RoomTransportCandidateRegistry();
      final subject = observer(bindings: bindings, candidates: candidates);
      final now = DateTime.utc(2026, 8, 26, 12);
      bindings.bind(
        peerKey: 'route-a',
        memberId: member('peer-a'),
        attachmentGeneration: 2,
      );
      subject.observePeer(
        peerKey: 'route-a',
        canHostHotspot: true,
        bluetoothSupported: true,
        backgroundReady: true,
        batteryPercent: 60,
        at: now,
        attachmentGeneration: 2,
      );

      subject.replaceAttachment(3);

      expect(candidates.snapshot(now: now, attachmentGeneration: 3), isEmpty);
      expect(
        subject.observePeer(
          peerKey: 'route-a',
          canHostHotspot: true,
          bluetoothSupported: true,
          backgroundReady: true,
          batteryPercent: 60,
          at: now,
          attachmentGeneration: 3,
        ),
        isFalse,
      );
    },
  );

  test('peer removal also removes its planner candidate', () {
    final bindings = RoomPeerMemberBindingRegistry(members: [member('peer-a')]);
    final candidates = RoomTransportCandidateRegistry();
    final subject = observer(bindings: bindings, candidates: candidates);
    final now = DateTime.utc(2026, 8, 26, 12);
    bindings.bind(
      peerKey: 'route-a',
      memberId: member('peer-a'),
      attachmentGeneration: 1,
    );
    subject.observePeer(
      peerKey: 'route-a',
      canHostHotspot: true,
      bluetoothSupported: false,
      backgroundReady: true,
      batteryPercent: 45,
      at: now,
      attachmentGeneration: 1,
    );

    subject.removePeer('route-a', attachmentGeneration: 1);

    expect(candidates.snapshot(now: now, attachmentGeneration: 1), isEmpty);
  });

  test('invalid battery evidence fails closed without assertion', () {
    final bindings = RoomPeerMemberBindingRegistry(members: [member('peer-a')]);
    final candidates = RoomTransportCandidateRegistry();
    final subject = observer(bindings: bindings, candidates: candidates);
    final now = DateTime.utc(2026, 8, 26, 12);
    bindings.bind(
      peerKey: 'route-a',
      memberId: member('peer-a'),
      attachmentGeneration: 1,
    );

    expect(
      subject.observePeer(
        peerKey: 'route-a',
        canHostHotspot: true,
        bluetoothSupported: true,
        backgroundReady: true,
        batteryPercent: 101,
        at: now,
        attachmentGeneration: 1,
      ),
      isFalse,
    );
    expect(candidates.snapshot(now: now, attachmentGeneration: 1), isEmpty);
  });
}
