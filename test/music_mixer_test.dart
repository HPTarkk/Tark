import 'package:flutter_test/flutter_test.dart';
import 'package:tark/feature/audio/domain/music_mixer.dart';

void main() {
  group('MusicMixer.mix', () {
    test('empty queue passes the voice frame through unchanged', () {
      final mixer = MusicMixer();
      expect(mixer.mix([0.1, -0.2, 0.3], 1.0), [0.1, -0.2, 0.3]);
    });

    test('applies a cubic taper to the slider gain', () {
      final mixer = MusicMixer()..addChunk([1.0]);
      // slider 0.5 → gain 0.125
      expect(mixer.mix([0.0], 0.5).single, closeTo(0.125, 1e-9));
    });

    test('clamps the mixed sample to ±1', () {
      final mixer = MusicMixer()..addChunk([1.0]);
      expect(mixer.mix([0.9], 1.0).single, 1.0);
    });

    test('mixes only as many samples as are queued, rest passthrough', () {
      final mixer = MusicMixer()..addChunk([0.5]);
      expect(mixer.mix([0.0, 0.25], 1.0), [0.5, 0.25]);
    });

    test('consumes queued samples across calls', () {
      final mixer = MusicMixer()..addChunk([0.5, 0.25]);
      expect(mixer.mix([0.0], 1.0), [0.5]);
      expect(mixer.mix([0.0], 1.0), [0.25]);
      expect(mixer.mix([0.0], 1.0), [0.0]);
    });
  });

  group('MusicMixer queue cap', () {
    test('drops the oldest samples over maxQueuedSamples', () {
      final mixer = MusicMixer(maxQueuedSamples: 2)..addChunk([0.1, 0.2, 0.3]);
      expect(mixer.mix([0.0, 0.0], 1.0), [0.2, 0.3]);
    });

    test('clear empties the queue', () {
      final mixer = MusicMixer()
        ..addChunk([0.5])
        ..clear();
      expect(mixer.mix([0.0], 1.0), [0.0]);
    });
  });

  group('MusicMixer.levelOf', () {
    test('empty chunk is 0', () {
      expect(MusicMixer.levelOf([]), 0);
    });

    test('computes RMS', () {
      expect(MusicMixer.levelOf([0.5, -0.5]), closeTo(0.5, 1e-9));
    });
  });
}
