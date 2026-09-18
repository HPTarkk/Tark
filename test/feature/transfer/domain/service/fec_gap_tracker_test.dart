import 'package:flutter_test/flutter_test.dart';
import 'package:tark/feature/transfer/domain/service/fec_gap_tracker.dart';

void main() {
  const sender = 'a1b2c3d4e5f6';
  const other = 'f6e5d4c3b2a1';

  group('FecGapTracker', () {
    // Nothing to rebuild from: the decoder has no state yet, and there is no
    // earlier packet to say one is missing.
    test('the first packet from a sender never recovers anything', () {
      final gaps = FecGapTracker();
      expect(gaps.observe(sender, 40), isFalse);
    });

    test('an unbroken sequence has nothing to recover', () {
      final gaps = FecGapTracker();
      gaps.observe(sender, 1);
      expect(gaps.observe(sender, 2), isFalse);
      expect(gaps.observe(sender, 3), isFalse);
    });

    test('exactly one missing packet is recoverable', () {
      final gaps = FecGapTracker();
      gaps.observe(sender, 1);
      expect(gaps.observe(sender, 3), isTrue);
    });

    // Opus carries a copy of the immediately preceding frame and no further
    // back, so the earlier of two missing packets is genuinely gone.
    test('two or more missing packets are not recoverable', () {
      final gaps = FecGapTracker();
      gaps.observe(sender, 1);
      expect(gaps.observe(sender, 4), isFalse);
      gaps.observe(sender, 10);
      expect(gaps.observe(sender, 40), isFalse);
    });

    test('after an unrecoverable gap the stream resumes normally', () {
      final gaps = FecGapTracker();
      gaps.observe(sender, 1);
      gaps.observe(sender, 10);
      expect(gaps.observe(sender, 11), isFalse);
      expect(gaps.observe(sender, 13), isTrue);
    });

    group('reordering', () {
      // The bug this class exists to prevent. Given 10, 12, 11, 13: 12
      // correctly recovers 11, then the real 11 arrives late. If the straggler
      // rewinds the sequence, 13 looks like a one-packet gap after 11 and
      // "recovers" 12 — a frame already played, decoded a second time and out
      // of order, which desynchronises the decoder for everything after it.
      test('a late straggler cannot manufacture a gap out of the next packet', () {
        final gaps = FecGapTracker();
        gaps.observe(sender, 10);
        expect(gaps.observe(sender, 12), isTrue); // recovers 11
        expect(gaps.observe(sender, 11), isFalse); // the real 11, late
        expect(gaps.observe(sender, 13), isFalse); // must NOT recover 12
      });

      test('a duplicate packet recovers nothing and moves nothing', () {
        final gaps = FecGapTracker();
        gaps.observe(sender, 5);
        gaps.observe(sender, 6);
        expect(gaps.observe(sender, 6), isFalse);
        expect(gaps.observe(sender, 7), isFalse);
        expect(gaps.observe(sender, 9), isTrue);
      });
    });

    group('per sender', () {
      // A WiFi channel carries several senders, each with its own independent
      // counter. One sender's numbering must never be read as another's gap.
      test('senders do not share a sequence', () {
        final gaps = FecGapTracker();
        gaps.observe(sender, 100);
        expect(gaps.observe(other, 5), isFalse);
        expect(gaps.observe(other, 7), isTrue);
        expect(gaps.observe(sender, 101), isFalse);
      });

      test('forgetting a sender starts it over rather than seeing a huge gap', () {
        final gaps = FecGapTracker();
        gaps.observe(sender, 900);
        gaps.forget(sender);
        expect(gaps.observe(sender, 2), isFalse);
        expect(gaps.observe(sender, 4), isTrue);
      });

      // A sequence remembered across a decoder reset would hand a recovery
      // attempt to a decoder with no state to build it from.
      test('clearing drops every sender', () {
        final gaps = FecGapTracker();
        gaps.observe(sender, 10);
        gaps.observe(other, 10);
        gaps.clear();
        expect(gaps.observe(sender, 12), isFalse);
        expect(gaps.observe(other, 12), isFalse);
      });
    });
  });
}
