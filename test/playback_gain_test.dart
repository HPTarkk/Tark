import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:tark/core/settings/audio_profile.dart';
import 'package:tark/feature/audio/domain/playback_gain.dart';

void main() {
  test('unity gain returns the identical list, allocating nothing', () {
    final gain = PlaybackGain();
    final input = [0.1, -0.4, 0.9];
    // Identity, not just equality: the RX hot path must pay nothing for this
    // stage existing, and the overwhelming majority of sessions never move it.
    expect(identical(gain.apply(input), input), isTrue);
  });

  test('scales quiet speech exactly, with no limiting in the way', () {
    final gain = PlaybackGain()..gain = 1.3;
    final out = gain.apply([0.1, -0.2, 0.5]);
    expect(out[0], closeTo(0.13, 1e-12));
    expect(out[1], closeTo(-0.26, 1e-12));
    expect(out[2], closeTo(0.65, 1e-12));
  });

  test('never clips, however hard it is driven', () {
    final gain = PlaybackGain()..gain = 4.0;
    final out = gain.apply([1.0, -1.0, 0.8, -0.95]);
    for (final s in out) {
      expect(s.abs(), lessThan(1.0));
    }
  });

  test('preserves sign', () {
    final gain = PlaybackGain()..gain = 3.0;
    final out = gain.apply([0.9, -0.9]);
    expect(out[0], greaterThan(0));
    expect(out[1], lessThan(0));
    expect(out[0], closeTo(-out[1], 1e-12));
  });

  test('is monotonic, so louder input is never quieter output', () {
    // A limiter that folded back would turn a shout into a quieter, wrong
    // sound — worse than the clipping it replaces.
    final gain = PlaybackGain()..gain = 2.5;
    final input = List<double>.generate(200, (i) => i / 199);
    final out = gain.apply(input);
    for (int i = 1; i < out.length; i++) {
      expect(out[i], greaterThanOrEqualTo(out[i - 1]));
    }
  });

  test('is continuous at the knee — no step for speech crossing it', () {
    final gain = PlaybackGain()..gain = 1.0001;
    // Sweep across the region where the soft knee engages and assert no
    // sample-to-sample jump larger than the input steps that caused it. A
    // discontinuity here would be an audible tick on every loud syllable.
    final input = List<double>.generate(2000, (i) => i / 1999);
    final out = (PlaybackGain()..gain = 1.4).apply(input);
    for (int i = 1; i < out.length; i++) {
      expect(out[i] - out[i - 1], lessThan(1.5 / 1999));
    }
    expect(gain.gain, closeTo(1.0001, 1e-12));
  });

  test('rejects a gain that would invert or destroy the waveform', () {
    final gain = PlaybackGain();
    gain.gain = -2.0;
    expect(gain.gain, 0.0);
    gain.gain = 1000.0;
    expect(gain.gain, 4.0);
    gain.gain = double.nan;
    expect(gain.gain, 1.0);
  });

  test('empty input is handled without touching the maths', () {
    expect((PlaybackGain()..gain = 2.0).apply(const <double>[]), isEmpty);
  });

  test("the riding preset's gain leaves normal speech undistorted", () {
    // Conversational speech sits well below full scale; at the preset's gain
    // the limiter should be entirely out of the picture for it, so the boost
    // is a clean level change rather than a tone change.
    final gain = PlaybackGain()..gain = RidingPreset.playbackGain;
    final speech = List<double>.generate(
      320,
      (i) => 0.3 * sin(2 * pi * i / 40),
    );
    final out = gain.apply(speech);
    for (int i = 0; i < speech.length; i++) {
      expect(out[i], closeTo(speech[i] * RidingPreset.playbackGain, 1e-12));
    }
  });
}
