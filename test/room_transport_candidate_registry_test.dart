import 'package:flutter_test/flutter_test.dart';
import 'package:tark/feature/room/domain/entity/room.dart';
import 'package:tark/feature/room/domain/service/room_transport_candidate_registry.dart';
import 'package:tark/feature/room/domain/service/room_transport_planner.dart';

void main() {
  RoomTransportCandidate candidate(String id, {int battery = 50}) =>
      RoomTransportCandidate(
        memberId: RoomMemberId(id),
        canHostHotspot: true,
        bluetoothSupported: true,
        backgroundReady: true,
        batteryPercent: battery,
      );

  final now = DateTime.utc(2026, 8, 26, 12);

  test('snapshot is stable and includes only the requested generation', () {
    final registry = RoomTransportCandidateRegistry();
    registry.observe(candidate('b' * 24), at: now, attachmentGeneration: 2);
    registry.observe(candidate('a' * 24), at: now, attachmentGeneration: 2);
    registry.observe(candidate('c' * 24), at: now, attachmentGeneration: 1);

    final snapshot = registry.snapshot(now: now, attachmentGeneration: 2);

    expect(snapshot.map((item) => item.memberId.value), ['a' * 24, 'b' * 24]);
  });

  test('older attachment observation cannot overwrite newer evidence', () {
    final registry = RoomTransportCandidateRegistry();
    final id = 'a' * 24;
    registry.observe(
      candidate(id, battery: 80),
      at: now,
      attachmentGeneration: 3,
    );
    registry.observe(
      candidate(id, battery: 10),
      at: now.add(const Duration(seconds: 1)),
      attachmentGeneration: 2,
    );

    final snapshot = registry.snapshot(
      now: now.add(const Duration(seconds: 1)),
      attachmentGeneration: 3,
    );

    expect(snapshot.single.batteryPercent, 80);
  });

  test('stale observations age out rather than winning a later election', () {
    final registry = RoomTransportCandidateRegistry(
      freshFor: const Duration(seconds: 5),
    );
    registry.observe(
      candidate('a' * 24, battery: 100),
      at: now,
      attachmentGeneration: 1,
    );
    registry.observe(
      candidate('b' * 24, battery: 40),
      at: now.add(const Duration(seconds: 4)),
      attachmentGeneration: 1,
    );

    final snapshot = registry.snapshot(
      now: now.add(const Duration(seconds: 6)),
      attachmentGeneration: 1,
    );

    expect(snapshot.map((item) => item.memberId.value), ['b' * 24]);
  });

  test('replacement drops previous attachment capability evidence', () {
    final registry = RoomTransportCandidateRegistry();
    registry.observe(candidate('a' * 24), at: now, attachmentGeneration: 1);
    registry.observe(candidate('b' * 24), at: now, attachmentGeneration: 2);

    registry.replaceAttachment(2);

    expect(registry.length, 1);
    expect(
      registry
          .snapshot(now: now, attachmentGeneration: 2)
          .single
          .memberId
          .value,
      'b' * 24,
    );
  });

  test('registry remains bounded and evicts the oldest observation', () {
    final registry = RoomTransportCandidateRegistry(maxCandidates: 2);
    registry.observe(candidate('a' * 24), at: now, attachmentGeneration: 1);
    registry.observe(
      candidate('b' * 24),
      at: now.add(const Duration(seconds: 1)),
      attachmentGeneration: 1,
    );
    registry.observe(
      candidate('c' * 24),
      at: now.add(const Duration(seconds: 2)),
      attachmentGeneration: 1,
    );

    final snapshot = registry.snapshot(
      now: now.add(const Duration(seconds: 2)),
      attachmentGeneration: 1,
    );

    expect(registry.length, 2);
    expect(snapshot.map((item) => item.memberId.value), ['b' * 24, 'c' * 24]);
  });

  test('removed peers and reset cannot retain candidate evidence', () {
    final registry = RoomTransportCandidateRegistry();
    final first = RoomMemberId('a' * 24);
    registry.observe(candidate(first.value), at: now, attachmentGeneration: 1);
    registry.remove(first);
    expect(registry.snapshot(now: now, attachmentGeneration: 1), isEmpty);

    registry.observe(candidate('b' * 24), at: now, attachmentGeneration: 1);
    registry.reset();
    expect(registry.snapshot(now: now, attachmentGeneration: 1), isEmpty);
  });

  test('disposed registry rejects later mutations and reads', () {
    final registry = RoomTransportCandidateRegistry();
    registry.dispose();

    expect(
      () => registry.observe(
        candidate('a' * 24),
        at: now,
        attachmentGeneration: 1,
      ),
      throwsStateError,
    );
    expect(
      () => registry.snapshot(now: now, attachmentGeneration: 1),
      throwsStateError,
    );
  });
}
