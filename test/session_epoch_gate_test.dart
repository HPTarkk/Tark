import 'package:flutter_test/flutter_test.dart';
import 'package:tark/core/identity/session_epoch.dart';
import 'package:tark/feature/transfer/domain/service/session_epoch_gate.dart';

void main() {
  const sender = 'f0243a6c52c7';
  const other = 'aa11bb22cc33';

  group('SessionEpochGate', () {
    test('adopts whatever epoch a sender is first heard on', () {
      final gate = SessionEpochGate();
      final v = gate.offer(sender, 3);
      expect(v.decision, EpochDecision.adopted);
      expect(v.isAccepted, isTrue);
      expect(gate.epochFor(sender), 3);
    });

    test('accepts everything that keeps arriving on the adopted epoch', () {
      final gate = SessionEpochGate();
      gate.offer(sender, 3);
      for (var i = 0; i < 200; i++) {
        expect(gate.offer(sender, 3).decision, EpochDecision.accepted);
      }
    });

    // The whole point. A packet from the join before this one carries a
    // sequence number from that join, and the jitter buffer cannot tell it
    // from the stream jumping backwards.
    test('drops a packet from the sender previous join', () {
      final gate = SessionEpochGate();
      gate.offer(sender, 5);
      final v = gate.offer(sender, 4);
      expect(v.decision, EpochDecision.stale);
      expect(v.isAccepted, isFalse);
      expect(v.previous, 5);
      expect(v.offered, 4);
      // The ghost must not move the gate: what follows it is still the live
      // session, and a gate that had rolled back would then drop all of it.
      expect(gate.epochFor(sender), 5);
    });

    test('a rejoin takes over immediately, with no grace period', () {
      final gate = SessionEpochGate();
      gate.offer(sender, 5);
      final v = gate.offer(sender, 6);
      expect(v.decision, EpochDecision.renewed);
      expect(v.isAccepted, isTrue);
      expect(v.previous, 5);
      expect(v.offered, 6);
      expect(gate.epochFor(sender), 6);
    });

    // The realistic shape of a rejoin: the new session starts delivering while
    // the tail of the old one is still draining out of a queue somewhere. The
    // new traffic must flow and only the stragglers may be dropped.
    test('interleaved ghosts are dropped while the new session flows', () {
      final gate = SessionEpochGate();
      gate.offer(sender, 5);
      gate.offer(sender, 6);

      var accepted = 0;
      var dropped = 0;
      for (var i = 0; i < 50; i++) {
        if (gate.offer(sender, 6).isAccepted) accepted++;
        if (!gate.offer(sender, 5).isAccepted) dropped++;
      }

      expect(accepted, 50);
      expect(dropped, 50);
      expect(gate.epochFor(sender), 6);
    });

    // Epochs are only ever compared within one sender, which is what lets them
    // be a bare counter — two phones sitting on the same number is normal and
    // must not make either invisible to the other.
    test('senders on the same epoch number do not interfere', () {
      final gate = SessionEpochGate();
      expect(gate.offer(sender, 1).isAccepted, isTrue);
      expect(gate.offer(other, 1).isAccepted, isTrue);
      gate.offer(sender, 2);
      // The first sender moving on says nothing about the second.
      expect(gate.offer(other, 1).decision, EpochDecision.accepted);
    });

    test('forgetting a sender lets it be adopted afresh', () {
      final gate = SessionEpochGate();
      gate.offer(sender, 9);
      gate.forget(sender);
      expect(gate.epochFor(sender), isNull);
      // Deliberately below the epoch it held: a sender we have dropped all
      // knowledge of gets whatever it presents next, rather than being judged
      // against a session neither side is in any more.
      expect(gate.offer(sender, 2).decision, EpochDecision.adopted);
    });

    test('clear drops every sender', () {
      final gate = SessionEpochGate();
      gate.offer(sender, 4);
      gate.offer(other, 4);
      gate.clear();
      expect(gate.epochFor(sender), isNull);
      expect(gate.epochFor(other), isNull);
    });
  });

  group('SessionEpoch', () {
    // kUnknownSessionEpoch is 0 and means "this sender said nothing". A live
    // session must never be able to emit it.
    test('never hands out the unknown-epoch sentinel', () {
      final epoch = SessionEpoch();
      expect(epoch.value, 0);
      expect(epoch.renew(), 1);
    });

    test('climbs once per join', () {
      final epoch = SessionEpoch();
      expect([epoch.renew(), epoch.renew(), epoch.renew()], [1, 2, 3]);
      expect(epoch.value, 3);
    });
  });
}
