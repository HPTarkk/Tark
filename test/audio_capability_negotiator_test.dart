import 'package:flutter_test/flutter_test.dart';
import 'package:tark/core/audio/audio_format_profile.dart';
import 'package:tark/feature/transfer/domain/service/audio_capability_negotiator.dart';

/// Bit for [AudioFormatProfile.hd24k] (id 2) per the class doc: bit `id - 2`.
const _hdBit = 1; // 1 << (2 - 2)

/// Bits for #29's media profiles, same id-2 scheme, sharing the one wire byte
/// with [_hdBit] rather than colliding with it.
const _mediaStereoBit = 2; // 1 << (3 - 2)
const _mediaMonoBit = 4; // 1 << (4 - 2)

/// A standalone list mirroring the real [AudioFormatProfile.supported] — kept
/// separate so this file's bit-matching tests don't silently change shape if
/// that list is ever extended further.
const _hdSupported = [AudioFormatProfile.hd24k, AudioFormatProfile.legacy16k];

AudioCapabilityNegotiator _hdNegotiator() =>
    AudioCapabilityNegotiator(supported: _hdSupported);

void main() {
  group('localBitmask (production default)', () {
    test('reflects every real, shipped profile — voice and media together', () {
      // #28 checkpoint 4: hd24k shipped past kDebugMode once the field
      // evidence attached to #28 cleared it for release, so every build now
      // advertises it. #29 checkpoint 2: media48kStereo/media48kMono ride
      // the same byte, so a build now advertises all three at once.
      expect(
        AudioCapabilityNegotiator.localBitmask,
        _hdBit | _mediaStereoBit | _mediaMonoBit,
      );
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

  group('AudioCapabilityNegotiator.media / resolveOptional', () {
    test('is ranked by mediaSupported, not the voice list', () {
      final n = AudioCapabilityNegotiator.media();
      // A voice-only bitmask (hd24k's bit) has no bearing on a media
      // negotiator — it is checking entirely different bits.
      n.observePeer('a', _hdBit);
      expect(n.resolveOptional(), isNull);
    });

    test('null with no peers known, unlike resolve()', () {
      expect(AudioCapabilityNegotiator.media().resolveOptional(), isNull);
    });

    test('one peer advertising stereo resolves to media48kStereo', () {
      final n = AudioCapabilityNegotiator.media()
        ..observePeer('a', _mediaStereoBit);
      expect(n.resolveOptional(), AudioFormatProfile.media48kStereo);
    });

    test('mono-only support resolves to media48kMono, not stereo', () {
      final n = AudioCapabilityNegotiator.media()
        ..observePeer('a', _mediaMonoBit);
      expect(n.resolveOptional(), AudioFormatProfile.media48kMono);
    });

    test('stereo ranks above mono when a peer advertises both', () {
      final n = AudioCapabilityNegotiator.media()
        ..observePeer('a', _mediaStereoBit | _mediaMonoBit);
      expect(n.resolveOptional(), AudioFormatProfile.media48kStereo);
    });

    test('one peer supporting neither media bit resolves to null', () {
      final n = AudioCapabilityNegotiator.media()
        ..observePeer('a', _mediaStereoBit)
        ..observePeer('b', 0);
      expect(n.resolveOptional(), isNull);
    });

    test('null again once every peer is forgotten, same as resolve()', () {
      final n = AudioCapabilityNegotiator.media()
        ..observePeer('a', _mediaStereoBit);
      n.forget('a');
      expect(n.resolveOptional(), isNull);
    });

    test('the real, shipped localBitmask satisfies a media negotiator', () {
      // Proves the two negotiators a real repository builds — voice and
      // media — actually agree with what this build's own presence claims,
      // rather than each testing an artificial bit in isolation.
      final n = AudioCapabilityNegotiator.media()
        ..observePeer('self-like-peer', AudioCapabilityNegotiator.localBitmask);
      expect(n.resolveOptional(), AudioFormatProfile.media48kStereo);
    });
  });
}
