import 'package:flutter_test/flutter_test.dart';
import 'package:tark/feature/audio/domain/media_channel_converter.dart';

void main() {
  group('MediaChannelConverter.downmixToMono', () {
    test('averages each interleaved L/R pair', () {
      final stereo = [1.0, 0.0, 0.0, 1.0, -1.0, -1.0];
      expect(MediaChannelConverter.downmixToMono(stereo), [0.5, 0.5, -1.0]);
    });

    test('halves the sample count for a real HD media frame', () {
      final frameSamples = 48000 * 20 ~/ 1000;
      final stereo = List<double>.filled(frameSamples * 2, 0.3);
      expect(
        MediaChannelConverter.downmixToMono(stereo).length,
        frameSamples,
      );
    });

    test('drops a truncated trailing sample rather than guessing', () {
      expect(MediaChannelConverter.downmixToMono([1.0, 1.0, 0.5]).length, 1);
    });

    test('never clips: two in-range channels cannot average out of range', () {
      final stereo = [1.0, 1.0, -1.0, -1.0, 1.0, -1.0];
      final mono = MediaChannelConverter.downmixToMono(stereo);
      for (final s in mono) {
        expect(s, inInclusiveRange(-1.0, 1.0));
      }
      expect(mono, [1.0, -1.0, 0.0]);
    });

    test('empty input yields empty output', () {
      expect(MediaChannelConverter.downmixToMono(const []), isEmpty);
    });

    test('is stateless: repeated calls never depend on prior ones', () {
      final first = MediaChannelConverter.downmixToMono([1.0, 1.0]);
      final second = MediaChannelConverter.downmixToMono([-1.0, -1.0]);
      final third = MediaChannelConverter.downmixToMono([1.0, 1.0]);
      expect(first, third);
      expect(second, [-1.0]);
    });
  });
}
