import 'package:flutter_test/flutter_test.dart';
import 'package:tark/feature/transfer/data/repository/broadcast_policy.dart';

void main() {
  group('needsBroadcastLeg', () {
    test('presence always broadcasts, however healthy the unicasts look', () {
      // Discovery has no unicast answer: a phone we have never heard from has
      // no address to aim at. Broadcast is the only way it learns we exist.
      expect(
        needsBroadcastLeg(
          isAudio: false,
          hasLivePeers: true,
          unicastFailing: false,
        ),
        isTrue,
      );
    });

    test('audio to live peers skips the broadcast — the field 2x case', () {
      // The regression this guards: sender out=+791/15s, receiver in=+1595,
      // with the playback buffer discarding exactly half as late arrivals.
      expect(
        needsBroadcastLeg(
          isAudio: true,
          hasLivePeers: true,
          unicastFailing: false,
        ),
        isFalse,
      );
    });

    test('audio broadcasts when there is no live peer to unicast to', () {
      // Recovery set, or nothing at all — where the audio should go is a guess,
      // so the wide leg goes back on.
      expect(
        needsBroadcastLeg(
          isAudio: true,
          hasLivePeers: false,
          unicastFailing: false,
        ),
        isTrue,
      );
    });

    test('audio broadcasts again once every unicast is failing', () {
      // Unicast is the leg we kept because it is known to have carried
      // traffic. The moment that stops being true it stops being trusted.
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
