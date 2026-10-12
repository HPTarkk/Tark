import 'dart:async';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tark/feature/room/domain/entity/room.dart';
import 'package:tark/feature/room/domain/entity/room_carrier.dart';
import 'package:tark/feature/room/domain/service/room_carrier_migration.dart';
import 'package:tark/feature/room/domain/service/room_carrier_promotion_controller.dart';
import 'package:tark/feature/room/domain/service/room_connection_readiness_gate.dart';

/// The pre-channel move, as a state machine: it ends in exactly one outcome,
/// never walks backwards, and calls the move done only once the other phone
/// has proven itself — repeatedly — somewhere other than the router.
void main() {
  final peer = RoomMemberId('p' * 24);
  final stranger = RoomMemberId('s' * 24);

  RoomPeerProofEvidence proof(String route, {RoomMemberId? from}) =>
      RoomPeerProofEvidence(
        memberId: from ?? peer,
        attachmentGeneration: 1,
        carrierRoute: route,
      );

  late _Mover mover;
  late StreamController<RoomPeerProofEvidence> proofs;
  late DateTime now;

  RoomCarrierMigration build() => RoomCarrierMigration(
    mover: mover,
    peer: peer,
    proofs: proofs.stream,
    previousRoute: '192.168.8.107',
    clock: () => now,
  );

  setUp(() {
    mover = _Mover();
    proofs = StreamController<RoomPeerProofEvidence>.broadcast(sync: true);
    now = DateTime.utc(2026, 10, 12, 9);
  });

  void advance(FakeAsync async, Duration by) {
    final step = const Duration(milliseconds: 250);
    var left = by;
    while (left > Duration.zero) {
      final d = left < step ? left : step;
      now = now.add(d);
      async.elapse(d);
      left -= d;
    }
  }

  test('host: established only after repeated proofs on the hotspot', () {
    fakeAsync((async) {
      mover.start = RoomCarrierPromotionStart.hosting;
      final migration = build();
      final steps = <RoomMigrationStep>[];
      migration.progressChanges.listen((p) => steps.add(p.step));
      RoomMigrationOutcome? outcome;
      migration.run().then((o) => outcome = o);
      async.flushMicrotasks();
      mover.emit(RoomCarrierStage.raising, localIsHost: true);
      mover.emit(RoomCarrierStage.moving, localIsHost: true);
      mover.emit(RoomCarrierStage.settled, localIsHost: true);

      // Still on the router: not evidence of anything.
      proofs.add(proof('192.168.8.107'));
      advance(async, const Duration(seconds: 1));
      proofs.add(proof('192.168.8.107'));
      expect(outcome, isNull);

      // On the hotspot, from someone else: ignored.
      proofs.add(proof('192.168.43.20', from: stranger));
      advance(async, const Duration(seconds: 1));
      expect(steps, isNot(contains(RoomMigrationStep.verifying)));

      proofs.add(proof('192.168.43.20'));
      expect(steps.last, RoomMigrationStep.verifying);
      advance(async, const Duration(seconds: 1));
      proofs.add(proof('192.168.43.20'));
      expect(outcome, isNull, reason: 'two proofs is not yet stable');
      advance(async, const Duration(seconds: 1));
      proofs.add(proof('192.168.43.20'));
      async.flushMicrotasks();

      expect(outcome?.result, RoomMigrationResult.moved);
      expect(outcome?.side, RoomMigrationSide.host);
      expect(steps, [
        RoomMigrationStep.electing,
        RoomMigrationStep.preparing,
        RoomMigrationStep.moving,
        RoomMigrationStep.verifying,
        RoomMigrationStep.established,
      ]);
      expect(mover.stoodDown, isFalse);
    });
  });

  test('a gap in the new-route proofs restarts the stability count', () {
    fakeAsync((async) {
      mover.start = RoomCarrierPromotionStart.following;
      final migration = build();
      RoomMigrationOutcome? outcome;
      migration.run().then((o) => outcome = o);
      async.flushMicrotasks();
      mover.emit(RoomCarrierStage.moving);

      proofs.add(proof('192.168.43.1'));
      advance(async, const Duration(seconds: 1));
      proofs.add(proof('192.168.43.1'));
      advance(async, const Duration(seconds: 5));
      proofs.add(proof('192.168.43.1'));
      expect(outcome, isNull);
      advance(async, const Duration(seconds: 1));
      proofs.add(proof('192.168.43.1'));
      advance(async, const Duration(seconds: 1));
      proofs.add(proof('192.168.43.1'));
      async.flushMicrotasks();
      expect(outcome?.result, RoomMigrationResult.moved);
    });
  });

  test('nothing to move to: stay, and stand the in-channel move down', () {
    fakeAsync((async) {
      mover.start = RoomCarrierPromotionStart.noEligibleHost;
      RoomMigrationOutcome? outcome;
      build().run().then((o) => outcome = o);
      async.flushMicrotasks();
      expect(outcome?.result, RoomMigrationResult.stay);
      expect(mover.stoodDown, isTrue);
    });
  });

  test('a declined join asks for the guided step instead of retrying', () {
    fakeAsync((async) {
      mover.start = RoomCarrierPromotionStart.following;
      RoomMigrationOutcome? outcome;
      build().run().then((o) => outcome = o);
      async.flushMicrotasks();
      mover.emit(RoomCarrierStage.moving);
      mover.emit(
        RoomCarrierStage.settled,
        failure: RoomCarrierMoveFailure.joinDeclined,
      );
      async.flushMicrotasks();
      expect(outcome?.result, RoomMigrationResult.needsGuidance);
      expect(outcome?.side, RoomMigrationSide.joiner);
      expect(outcome?.failure, RoomCarrierMoveFailure.joinDeclined);
      expect(mover.stoodDown, isTrue);
    });
  });

  test('a host that went silent on the router hands the joiner to the '
      'guided step without the full deadline', () {
    fakeAsync((async) {
      mover.start = RoomCarrierPromotionStart.following;
      RoomMigrationOutcome? outcome;
      build().run().then((o) => outcome = o);
      async.flushMicrotasks();
      mover.emit(RoomCarrierStage.awaitingHost);
      advance(async, const Duration(seconds: 9));
      expect(outcome, isNull);
      advance(async, const Duration(seconds: 2));
      expect(outcome?.result, RoomMigrationResult.needsGuidance);
      expect(outcome?.failure, RoomCarrierMoveFailure.timedOut);
    });
  });

  test('the host waits for the joiner, then asks for the guided step', () {
    fakeAsync((async) {
      mover.start = RoomCarrierPromotionStart.hosting;
      RoomMigrationOutcome? outcome;
      build().run().then((o) => outcome = o);
      async.flushMicrotasks();
      mover.emit(RoomCarrierStage.moving, localIsHost: true);
      mover.emit(RoomCarrierStage.settled, localIsHost: true);
      advance(async, const Duration(seconds: 29));
      expect(outcome, isNull);
      advance(async, const Duration(seconds: 2));
      expect(outcome?.result, RoomMigrationResult.needsGuidance);
      expect(outcome?.side, RoomMigrationSide.host);
    });
  });

  test('an announcement that landed before the election finished still '
      'counts', () {
    fakeAsync((async) {
      // The other phone decided first; this one is already moving by the
      // time its own election returns.
      mover.status = const RoomCarrierStatus(
        stage: RoomCarrierStage.moving,
        durability: RoomCarrierDurability.owned,
        generation: 1,
      );
      mover.start = RoomCarrierPromotionStart.alreadyMoving;
      final migration = build();
      RoomMigrationOutcome? outcome;
      migration.run().then((o) => outcome = o);
      async.flushMicrotasks();
      expect(migration.progress.step, RoomMigrationStep.moving);
      expect(migration.progress.side, RoomMigrationSide.joiner);
      for (var i = 0; i < 3; i++) {
        proofs.add(proof('10.42.0.1'));
        advance(async, const Duration(seconds: 1));
      }
      expect(outcome?.result, RoomMigrationResult.moved);
    });
  });

  test('abandoning ends it at once', () {
    fakeAsync((async) {
      mover.start = RoomCarrierPromotionStart.hosting;
      final abandon = Completer<void>();
      RoomMigrationOutcome? outcome;
      build().run(abandoned: abandon.future).then((o) => outcome = o);
      async.flushMicrotasks();
      abandon.complete();
      async.flushMicrotasks();
      expect(outcome?.result, RoomMigrationResult.abandoned);
    });
  });
}

class _Mover implements RoomCarrierMover {
  RoomCarrierPromotionStart start = RoomCarrierPromotionStart.noPeers;
  bool stoodDown = false;
  final _changes = StreamController<RoomCarrierStatus>.broadcast(sync: true);

  @override
  RoomCarrierStatus status = const RoomCarrierStatus(
    stage: RoomCarrierStage.settled,
    durability: RoomCarrierDurability.borrowed,
    generation: 0,
  );

  void emit(
    RoomCarrierStage stage, {
    bool localIsHost = false,
    RoomCarrierMoveFailure? failure,
  }) {
    status = RoomCarrierStatus(
      stage: stage,
      durability: RoomCarrierDurability.borrowed,
      generation: 1,
      localIsHost: localIsHost,
      failure: failure,
    );
    _changes.add(status);
  }

  @override
  Stream<RoomCarrierStatus> get statusChanges => _changes.stream;

  @override
  Future<RoomCarrierPromotionStart> promoteNow() async => start;

  @override
  void standDown() => stoodDown = true;
}
