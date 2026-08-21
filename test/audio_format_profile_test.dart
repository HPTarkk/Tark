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
  });

  group('registry', () {
    test('ids are unique and stable', () {
      expect(AudioFormatProfile.legacy16k.id, 1);
      expect(AudioFormatProfile.hd24k.id, 2);
    });

    test('supported is legacy-only until negotiation lands', () {
      expect(AudioFormatProfile.supported, [AudioFormatProfile.legacy16k]);
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
  });
}
