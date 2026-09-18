import 'package:flutter_test/flutter_test.dart';
import 'package:tark/feature/transfer/domain/service/peer_loss_tracker.dart';

void main() {
  const peer = 'a1b2c3d4e5f6';
  const other = 'f6e5d4c3b2a1';

  group('PeerLossTracker', () {
    // The first pong only establishes the baseline both later windows are
    // measured against — there is no earlier point to diff it with.
    test('the first sample only sets a baseline', () {
      final tracker = PeerLossTracker();
      expect(
        tracker.sample(peer, ourSentCount: 500, theirReceivedCount: 480),
        isNull,
      );
      expect(tracker.lossFor(peer), isNull);
      expect(tracker.worstLossFraction, 0.0);
    });

    test('a peer receiving everything we sent reports no loss', () {
      final tracker = PeerLossTracker();
      tracker.sample(peer, ourSentCount: 0, theirReceivedCount: 0);
      final loss = tracker.sample(
        peer,
        ourSentCount: 100,
        theirReceivedCount: 100,
      );
      expect(loss, 0.0);
    });

    test('a peer missing a tenth of our audio reports a tenth', () {
      final tracker = PeerLossTracker();
      tracker.sample(peer, ourSentCount: 0, theirReceivedCount: 0);
      final loss = tracker.sample(
        peer,
        ourSentCount: 100,
        theirReceivedCount: 90,
      );
      expect(loss, closeTo(0.10, 1e-9));
    });

    // Nobody is talking, so almost no audio was sent. Dividing by that would
    // report wild loss for a link doing nothing wrong.
    test('a window with too little audio does not produce a figure', () {
      final tracker = PeerLossTracker();
      tracker.sample(peer, ourSentCount: 0, theirReceivedCount: 0);
      expect(
        tracker.sample(peer, ourSentCount: 5, theirReceivedCount: 0),
        isNull,
      );
      expect(tracker.lossFor(peer), isNull);
    });

    // The counts are sampled a round trip apart, so a peer can report having
    // received packets we had not yet counted as sent. That is skew, not
    // negative loss.
    test('a peer ahead of our own count is not negative loss', () {
      final tracker = PeerLossTracker();
      tracker.sample(peer, ourSentCount: 0, theirReceivedCount: 0);
      final loss = tracker.sample(
        peer,
        ourSentCount: 100,
        theirReceivedCount: 105,
      );
      expect(loss, 0.0);
    });

    // Loss on a hotspot arrives in bursts. Retuning to full redundancy for one
    // of them and back again is worse than either setting.
    test('one bad window moves the estimate without committing to it', () {
      final tracker = PeerLossTracker(smoothing: 0.4);
      tracker.sample(peer, ourSentCount: 0, theirReceivedCount: 0);
      // A clean window first, so there is an estimate to move away from.
      tracker.sample(peer, ourSentCount: 100, theirReceivedCount: 100);
      final afterBurst = tracker.sample(
        peer,
        ourSentCount: 200,
        theirReceivedCount: 150,
      );
      // The window itself was 50 % lost; the estimate takes 40 % of the step.
      expect(afterBurst, closeTo(0.20, 1e-9));

      // A second window losing the same half commits.
      final afterSecond = tracker.sample(
        peer,
        ourSentCount: 300,
        theirReceivedCount: 200,
      );
      expect(afterSecond, greaterThan(afterBurst!));
    });

    // The other half of the same property: once the burst passes, the estimate
    // has to come back down, or the encoder would spend the rest of the ride
    // paying for redundancy against loss that stopped happening.
    test('a clean window walks the estimate back down', () {
      final tracker = PeerLossTracker(smoothing: 0.4);
      tracker.sample(peer, ourSentCount: 0, theirReceivedCount: 0);
      final lossy = tracker.sample(
        peer,
        ourSentCount: 100,
        theirReceivedCount: 50,
      );
      final recovered = tracker.sample(
        peer,
        ourSentCount: 200,
        theirReceivedCount: 150,
      );
      expect(recovered, lessThan(lossy!));
    });

    group('restarts', () {
      // A sequence counter restarts with the transport while the device
      // identity keying this map does not, so both counters can go backwards
      // under a peer that is working perfectly.
      test('a peer whose counters restart rebases instead of reporting loss', () {
        final tracker = PeerLossTracker();
        tracker.sample(peer, ourSentCount: 0, theirReceivedCount: 0);
        tracker.sample(peer, ourSentCount: 500, theirReceivedCount: 500);
        expect(tracker.lossFor(peer), 0.0);

        // The peer rejoined: its received count starts again from nothing.
        final afterRestart = tracker.sample(
          peer,
          ourSentCount: 600,
          theirReceivedCount: 4,
        );
        // The previous estimate survives; the restart itself is not evidence.
        expect(afterRestart, 0.0);

        // And the new baseline is the one measured from.
        final next = tracker.sample(
          peer,
          ourSentCount: 700,
          theirReceivedCount: 104,
        );
        expect(next, 0.0);
      });
    });

    group('worst peer', () {
      // One encoded packet goes to every peer, so the stream has to survive the
      // worst link it is addressed to. Averaging would let two good peers vote
      // a third into unintelligibility.
      test('the worst peer decides, not the average', () {
        final tracker = PeerLossTracker();
        tracker.sample(peer, ourSentCount: 0, theirReceivedCount: 0);
        tracker.sample(other, ourSentCount: 0, theirReceivedCount: 0);

        tracker.sample(peer, ourSentCount: 100, theirReceivedCount: 100);
        tracker.sample(other, ourSentCount: 100, theirReceivedCount: 70);

        expect(tracker.worstLossFraction, closeTo(0.30, 1e-9));
        expect(tracker.worstPeerId, other);
      });

      test('a peer that leaves stops counting against the link', () {
        final tracker = PeerLossTracker();
        tracker.sample(other, ourSentCount: 0, theirReceivedCount: 0);
        tracker.sample(other, ourSentCount: 100, theirReceivedCount: 60);
        expect(tracker.worstLossFraction, closeTo(0.40, 1e-9));

        tracker.forget(other);
        expect(tracker.worstLossFraction, 0.0);
        expect(tracker.worstPeerId, isNull);
      });

      // A rider who drops off the back of the group at 40 % loss must not go on
      // being the worst peer for the rest of the session — that would hold the
      // encoder at its lowest bitrate for everyone still talking.
      test('ageing the roster expires the estimates of peers who have gone', () {
        final tracker = PeerLossTracker();
        tracker.sample(peer, ourSentCount: 0, theirReceivedCount: 0);
        tracker.sample(other, ourSentCount: 0, theirReceivedCount: 0);
        tracker.sample(peer, ourSentCount: 100, theirReceivedCount: 98);
        tracker.sample(other, ourSentCount: 100, theirReceivedCount: 60);
        expect(tracker.worstPeerId, other);

        tracker.retain([peer]);
        expect(tracker.worstPeerId, peer);
        expect(tracker.worstLossFraction, closeTo(0.02, 1e-9));
      });

      test('an empty roster leaves nothing behind', () {
        final tracker = PeerLossTracker();
        tracker.sample(peer, ourSentCount: 0, theirReceivedCount: 0);
        tracker.sample(peer, ourSentCount: 100, theirReceivedCount: 50);
        tracker.retain(const []);
        expect(tracker.worstLossFraction, 0.0);
      });
    });
  });
}
