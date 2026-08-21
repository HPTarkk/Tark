import 'package:flutter/foundation.dart' show kDebugMode;
import 'package:flutter_test/flutter_test.dart';
import 'package:tark/core/audio/audio_format_profile.dart';
import 'package:tark/feature/transfer/domain/service/audio_capability_negotiator.dart';

/// Bit for [AudioFormatProfile.hd24k] (id 2) per the class doc: bit `id - 2`.
const _hdBit = 1; // 1 << (2 - 2)

/// Only [AudioFormatProfile.hd24k]/[AudioFormatProfile.legacy16k] are testing
/// the bit-matching logic itself against a profile above legacy16k,
/// independently of when the real [AudioFormatProfile.supported] grows past
/// it (checkpoint 3) — see [AudioCapabilityNegotiator]'s constructor doc.
const _hdSupported = [AudioFormatProfile.hd24k, AudioFormatProfile.legacy16k];

AudioCapabilityNegotiator _hdNegotiator() =>
    AudioCapabilityNegotiator(supported: _hdSupported);

void main() {
  group('localBitmask (production default)', () {
    test('reflects the real, kDebugMode-gated AudioFormatProfile.supported', () {
      // #28 checkpoint 3 gates hd24k to kDebugMode until a physical
      // motorcycle A/B clears it for release (see AudioFormatProfile
      // .supported) — checked dynamically so this passes in both build
      // modes rather than assuming whichever one `flutter test` happens to
      // run in.
      expect(AudioCapabilityNegotiator.localBitmask, kDebugMode ? _hdBit : 0);
    });
  });

  group('resolve with no peers known', () {
    test('is legacy16k even with a fresh negotiator', () {
      expect(_hdNegotiator().resolve(), AudioFormatProfile.legacy16k);
    });

    test('is legacy16k again once every peer has been forgotten', () {
      final n = _hdNegotiator()..observePeer('a', _hdBit);
      n.forget('a');
      expect(n.resolve(), AudioFormatProfile.legacy16k);
    });

    test('is legacy16k again once retain drops every peer', () {
      final n = _hdNegotiator()
        ..observePeer('a', _hdBit)
        ..observePeer('b', _hdBit);
      n.retain(const []);
      expect(n.resolve(), AudioFormatProfile.legacy16k);
    });

    test('clear resets to legacy16k the same way', () {
      final n = _hdNegotiator()..observePeer('a', _hdBit);
      n.clear();
      expect(n.resolve(), AudioFormatProfile.legacy16k);
    });
  });

  group('resolve with peers known', () {
    test('one peer advertising the bit resolves to that profile', () {
      final n = _hdNegotiator()..observePeer('a', _hdBit);
      expect(n.resolve(), AudioFormatProfile.hd24k);
    });

    test('two peers both advertising resolves up', () {
      final n = _hdNegotiator()
        ..observePeer('a', _hdBit)
        ..observePeer('b', _hdBit);
      expect(n.resolve(), AudioFormatProfile.hd24k);
    });

    test('one peer NOT advertising holds the whole roster to legacy16k', () {
      final n = _hdNegotiator()
        ..observePeer('a', _hdBit)
        ..observePeer('b', 0);
      expect(n.resolve(), AudioFormatProfile.legacy16k);
    });

    test('a peer that never advertises (bitmask 0) resolves to legacy16k', () {
      final n = _hdNegotiator()..observePeer('old-build', 0);
      expect(n.resolve(), AudioFormatProfile.legacy16k);
    });

    test('re-observing the same peer with a new bitmask changes the result', () {
      final n = _hdNegotiator()..observePeer('a', 0);
      expect(n.resolve(), AudioFormatProfile.legacy16k);
      n.observePeer('a', _hdBit);
      expect(n.resolve(), AudioFormatProfile.hd24k);
    });

    test('retain drops the holdout, letting the roster resolve up', () {
      final n = _hdNegotiator()
        ..observePeer('capable', _hdBit)
        ..observePeer('holdout', 0);
      expect(n.resolve(), AudioFormatProfile.legacy16k);
      n.retain(['capable']); // holdout left the roster
      expect(n.resolve(), AudioFormatProfile.hd24k);
    });

    test('observePeer is idempotent — repeated identical calls change nothing observable', () {
      final n = _hdNegotiator();
      for (var i = 0; i < 5; i++) {
        n.observePeer('a', _hdBit);
      }
      expect(n.resolve(), AudioFormatProfile.hd24k);
    });
  });

  group('no coordination needed — symmetric computation', () {
    test('swapping which side is "us" vs "the peer" yields the same resolve()', () {
      // Both sides of a link run the identical algorithm against the same
      // inputs (their own capabilities are baked into .supported at build
      // time; what differs is only whose bitmask is "mine" vs "the peer's"
      // in each one's own negotiator). This proves the computation doesn't
      // depend on which side asks it — no ack round trip is needed.
      final mine = _hdNegotiator()..observePeer('peer', _hdBit);
      final theirs = _hdNegotiator()..observePeer('me', _hdBit);
      expect(mine.resolve(), theirs.resolve());
    });

    test('and the same holds when neither side supports the higher profile', () {
      final mine = _hdNegotiator()..observePeer('peer', 0);
      final theirs = _hdNegotiator()..observePeer('me', 0);
      expect(mine.resolve(), theirs.resolve());
      expect(mine.resolve(), AudioFormatProfile.legacy16k);
    });
  });

  group('mixed-version fallback', () {
    test('a peer whose presence carries no capability opinion pins the roster at legacy16k', () {
      // Bitmask 0 is exactly what an old build's absent trailing byte reads
      // back as (see WakiPacketCodec.decode) — this is the fallback case
      // from the peer's side, expressed at the negotiator level, and it
      // holds even when every other peer is HD-capable.
      final n = _hdNegotiator()
        ..observePeer('modern-a', _hdBit)
        ..observePeer('legacy-peer', 0)
        ..observePeer('modern-b', _hdBit);
      expect(n.resolve(), AudioFormatProfile.legacy16k);
    });
  });
}
