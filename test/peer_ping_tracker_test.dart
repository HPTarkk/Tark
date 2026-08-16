import 'package:flutter_test/flutter_test.dart';
import 'package:tark/feature/transfer/data/repository/broadcast_policy.dart';
import 'package:tark/feature/transfer/domain/service/peer_ping_tracker.dart';

void main() {
  final t0 = DateTime(2026, 8, 16, 11, 0);
  const peer = '192.168.43.7';
  const other = '192.168.43.9';

  group('PeerPingTracker', () {
    test('a peer that answers reports its round trip', () {
      final tracker = PeerPingTracker();
      tracker.sent(peer, 1, t0);
      final rtt = tracker.pong(
        peer,
        1,
        t0.add(const Duration(milliseconds: 24)),
      );
      expect(rtt, const Duration(milliseconds: 24));
      expect(tracker.rttFor(peer), const Duration(milliseconds: 24));
    });

    // Timing a late pong against the most recent ping would report an RTT far
    // shorter than the truth, which is worse than reporting none.
    test('a pong is timed against the ping that caused it', () {
      final tracker = PeerPingTracker();
      tracker.sent(peer, 1, t0);
      tracker.sent(peer, 2, t0.add(const Duration(seconds: 1)));
      final rtt = tracker.pong(
        peer,
        1,
        t0.add(const Duration(milliseconds: 1200)),
      );
      expect(rtt, const Duration(milliseconds: 1200));
    });

    test('an unmatched token confirms the peer but yields no timing', () {
      final tracker = PeerPingTracker();
      tracker.sent(peer, 1, t0);
      final rtt = tracker.pong(peer, 999, t0.add(const Duration(seconds: 1)));
      expect(rtt, isNull);
      // Still an answer: the peer plainly sent something back.
      expect(tracker.confirmedAt(peer), isNotNull);
      expect(
        tracker.isUnconfirmed(peer, t0.add(const Duration(seconds: 2))),
        isFalse,
      );
    });

    group('unconfirmed', () {
      test('an address never pinged has no opinion attached to it', () {
        final tracker = PeerPingTracker();
        expect(tracker.isUnconfirmed(peer, t0), isFalse);
      });

      // A peer discovered a moment ago has not had a chance to answer; grading
      // it would declare every new arrival broken for its first few seconds.
      test('a peer inside the grace is not yet judged', () {
        final tracker = PeerPingTracker();
        tracker.sent(peer, 1, t0);
        expect(
          tracker.isUnconfirmed(peer, t0.add(const Duration(seconds: 5))),
          isFalse,
        );
      });

      // The case the whole mechanism exists for: still heard, still in the
      // peer map, and our unicast audio is reaching nobody.
      test('a peer silent past the grace is unconfirmed', () {
        final tracker = PeerPingTracker();
        tracker.sent(peer, 1, t0);
        expect(
          tracker.isUnconfirmed(peer, t0.add(const Duration(seconds: 7))),
          isTrue,
        );
      });

      test('one dropped ping is never enough', () {
        final tracker = PeerPingTracker();
        tracker.sent(peer, 1, t0);
        tracker.pong(peer, 1, t0);
        // Next ping goes unanswered, but only for a second.
        tracker.sent(peer, 2, t0.add(const Duration(seconds: 1)));
        expect(
          tracker.isUnconfirmed(peer, t0.add(const Duration(seconds: 2))),
          isFalse,
        );
      });

      test(
        'a peer that answered and then went silent is unconfirmed again',
        () {
          final tracker = PeerPingTracker();
          tracker.sent(peer, 1, t0);
          tracker.pong(peer, 1, t0);
          expect(
            tracker.isUnconfirmed(peer, t0.add(const Duration(seconds: 7))),
            isTrue,
          );
        },
      );

      test('names only the peers that have stopped answering', () {
        final tracker = PeerPingTracker();
        tracker.sent(peer, 1, t0);
        tracker.sent(other, 2, t0);
        tracker.pong(other, 2, t0.add(const Duration(seconds: 6)));
        final now = t0.add(const Duration(seconds: 7));
        expect(tracker.unconfirmedAmong([peer, other], now), [peer]);
      });
    });

    test('a peer that never answers cannot grow unbounded pending state', () {
      final tracker = PeerPingTracker();
      for (var i = 0; i < 500; i++) {
        tracker.sent(peer, i, t0.add(Duration(seconds: i)));
      }
      // Bounded — and the most recent ping is still matchable, which is the
      // one a late pong would be answering.
      final rtt = tracker.pong(peer, 499, t0.add(const Duration(seconds: 500)));
      expect(rtt, const Duration(seconds: 1));
    });

    test('forgetting a peer clears everything about it', () {
      final tracker = PeerPingTracker();
      tracker.sent(peer, 1, t0);
      tracker.pong(peer, 1, t0);
      tracker.forget(peer);
      expect(tracker.rttFor(peer), isNull);
      expect(tracker.confirmedAt(peer), isNull);
      expect(
        tracker.isUnconfirmed(peer, t0.add(const Duration(hours: 1))),
        isFalse,
      );
    });
  });

  group('needsBroadcastLeg', () {
    test('presence always takes the broadcast leg — that is discovery', () {
      expect(
        needsBroadcastLeg(
          isAudio: false,
          hasLivePeers: true,
          unicastFailing: false,
        ),
        isTrue,
      );
    });

    test('audio skips it once peers are known and answering', () {
      expect(
        needsBroadcastLeg(
          isAudio: true,
          hasLivePeers: true,
          unicastFailing: false,
        ),
        isFalse,
      );
    });

    // The fix. A peer heard but not answering unicast means our audio is not
    // reaching it, and the broadcast leg is the only way back to it.
    test('an unconfirmed unicast path puts audio back on broadcast', () {
      expect(
        needsBroadcastLeg(
          isAudio: true,
          hasLivePeers: true,
          unicastFailing: false,
          unicastUnconfirmed: true,
        ),
        isTrue,
      );
    });

    test('the existing two escapes still work', () {
      expect(
        needsBroadcastLeg(
          isAudio: true,
          hasLivePeers: false,
          unicastFailing: false,
        ),
        isTrue,
      );
      expect(
        needsBroadcastLeg(
          isAudio: true,
          hasLivePeers: true,
          unicastFailing: true,
        ),
        isTrue,
      );
    });
  });
}
