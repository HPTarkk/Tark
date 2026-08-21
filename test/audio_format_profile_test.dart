import 'package:flutter_test/flutter_test.dart';
import 'package:tark/core/audio/audio_format_profile.dart';

void main() {
  group('frameSamples derivation', () {
    test('legacy16k is 20ms @ 16kHz = 320 samples', () {
      expect(AudioFormatProfile.legacy16k.sampleRateHz, 16000);
      expect(AudioFormatProfile.legacy16k.frameDurationMs, 20);
      expect(AudioFormatProfile.legacy16k.frameSamples, 320);
    });

    test('hd24k is 20ms @ 24kHz = 480 samples', () {
      expect(AudioFormatProfile.hd24k.sampleRateHz, 24000);
      expect(AudioFormatProfile.hd24k.frameDurationMs, 20);
      expect(AudioFormatProfile.hd24k.frameSamples, 480);
    });

    test('media48kStereo is 20ms @ 48kHz = 960 samples/channel', () {
      expect(AudioFormatProfile.media48kStereo.sampleRateHz, 48000);
      expect(AudioFormatProfile.media48kStereo.frameDurationMs, 20);
      expect(AudioFormatProfile.media48kStereo.frameSamples, 960);
      expect(AudioFormatProfile.media48kStereo.channels, 2);
    });

    test('media48kMono matches media48kStereo\'s rate/frame, mono channels', () {
      expect(AudioFormatProfile.media48kMono.sampleRateHz, 48000);
      expect(AudioFormatProfile.media48kMono.frameSamples, 960);
      expect(AudioFormatProfile.media48kMono.channels, 1);
    });
  });

  group('registry', () {
    test('ids are unique and stable', () {
      expect(AudioFormatProfile.legacy16k.id, 1);
      expect(AudioFormatProfile.hd24k.id, 2);
      expect(AudioFormatProfile.media48kStereo.id, 3);
      expect(AudioFormatProfile.media48kMono.id, 4);
    });

    test('every shipped profile has a unique id', () {
      final ids = [
        ...AudioFormatProfile.supported,
        ...AudioFormatProfile.mediaSupported,
      ].map((p) => p.id);
      expect(ids.toSet().length, ids.length);
    });

    test('supported is hd24k-then-legacy16k in every build', () {
      // #28 checkpoint 4: widened past kDebugMode once the field evidence
      // (two-device negotiation + reliability data attached to #28) cleared
      // it for release. legacy16k stays second, and reachable, as the
      // fallback for any peer that never advertises hd24k support.
      expect(AudioFormatProfile.supported, [
        AudioFormatProfile.hd24k,
        AudioFormatProfile.legacy16k,
      ]);
    });

    test('supported carries only voice profiles', () {
      expect(
        AudioFormatProfile.supported.every(
          (p) => p.kind == AudioProfileKind.voice,
        ),
        isTrue,
      );
    });

    test('mediaSupported is stereo-then-mono, media kind only', () {
      expect(AudioFormatProfile.mediaSupported, [
        AudioFormatProfile.media48kStereo,
        AudioFormatProfile.media48kMono,
      ]);
      expect(
        AudioFormatProfile.mediaSupported.every(
          (p) => p.kind == AudioProfileKind.media,
        ),
        isTrue,
      );
    });

    test('equality is by value, not identity', () {
      expect(
        AudioFormatProfile.legacy16k,
        const AudioFormatProfile(
          id: 1,
          sampleRateHz: 16000,
          channels: 1,
          frameDurationMs: 20,
          label: '16k',
        ),
      );
    });

    test('kind participates in equality', () {
      const voiceShaped = AudioFormatProfile(
        id: 3,
        sampleRateHz: 48000,
        channels: 2,
        frameDurationMs: 20,
        label: '48k-HD-stereo',
      ); // kind defaults to voice — same shape as media48kStereo otherwise.
      expect(voiceShaped, isNot(AudioFormatProfile.media48kStereo));
    });
  });
}
