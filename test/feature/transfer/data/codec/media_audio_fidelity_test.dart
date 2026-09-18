import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:tark/core/audio/audio_format_profile.dart';
import 'package:tark/feature/transfer/data/codec/opus_audio_codec.dart';
import 'package:tark/feature/transfer/domain/service/media_opus_tuner.dart';
import 'package:tark/feature/transfer/domain/service/opus_tuner.dart';

/// Multi-tone fixture, same `List.generate` + `sin()` convention as
/// `spectral_noise_suppressor_test.dart`. No copyrighted audio in the repo —
/// every signal here is synthetic.
List<double> _tone(int n, int sampleRate, List<double> freqsHz, {int start = 0}) {
  return List<double>.generate(n, (i) {
    final t = (start + i) / sampleRate;
    var v = 0.0;
    for (final f in freqsHz) {
      v += sin(2 * pi * f * t) / freqsHz.length;
    }
    return v * 0.6; // headroom, same reasoning as MusicMixer's clamp
  });
}

/// Interleaves [left]/[right] (equal length) into one stereo buffer.
List<double> _interleave(List<double> left, List<double> right) {
  final out = Float64List(left.length * 2);
  for (var i = 0; i < left.length; i++) {
    out[i * 2] = left[i];
    out[i * 2 + 1] = right[i];
  }
  return out;
}

(List<double>, List<double>) _deinterleave(List<double> stereo) {
  final n = stereo.length ~/ 2;
  final left = List<double>.generate(n, (i) => stereo[i * 2]);
  final right = List<double>.generate(n, (i) => stereo[i * 2 + 1]);
  return (left, right);
}

double _correlation(List<double> a, List<double> b) {
  assert(a.length == b.length);
  var num = 0.0, da = 0.0, db = 0.0;
  for (var i = 0; i < a.length; i++) {
    num += a[i] * b[i];
    da += a[i] * a[i];
    db += b[i] * b[i];
  }
  if (da == 0 || db == 0) return 0;
  return num / sqrt(da * db);
}

void main() {
  setUpAll(() => OpusAudioCodec.ensureInitialized());

  // Same guard `rnnoise_suppressor_test.dart` uses: the native codec may not
  // load on every machine that runs this suite, and the fallback rungs exist
  // precisely so that isn't fatal — but round-trip fidelity assertions only
  // mean something against the real encoder, so they're skipped rather than
  // faked when it didn't load.
  final available = OpusAudioCodec.isAvailable;

  group('media profile — codec independence', () {
    test('a voice instance and a media instance never share state', () {
      final voice = OpusAudioCodec()
        ..setFormatProfile(AudioFormatProfile.legacy16k)
        ..setProfile(OpusEncodeProfile.voice);
      final media = OpusAudioCodec()
        ..setFormatProfile(AudioFormatProfile.media48kStereo)
        ..setProfile(OpusEncodeProfile.music);

      if (!available) return;

      final voiceFrame = _tone(
        AudioFormatProfile.legacy16k.frameSamples,
        16000,
        [300],
      );
      final mediaFrame = _interleave(
        _tone(AudioFormatProfile.media48kStereo.frameSamples, 48000, [440]),
        _tone(AudioFormatProfile.media48kStereo.frameSamples, 48000, [440]),
      );

      for (var i = 0; i < 20; i++) {
        final vPacket = voice.encode(voiceFrame);
        final mPacket = media.encode(mediaFrame);
        expect(vPacket, isNotNull, reason: 'voice frame $i');
        expect(mPacket, isNotNull, reason: 'media frame $i');

        final vOut = voice.decode(vPacket!, 'peer', i);
        final mOut = media.decode(mPacket!, 'peer', i);
        expect(vOut!.samples.length, AudioFormatProfile.legacy16k.frameSamples);
        expect(
          mOut!.samples.length,
          AudioFormatProfile.media48kStereo.frameSamples * 2,
        );
      }

      // Retuning one instance must not reach the other — each holds its own
      // `_tuning` field, so `media` should still be exactly where it started.
      final mediaTuningBefore = media.tuning;
      voice.applyTuning(
        const MediaOpusTuner().tune(const AudioLinkConditions()),
      );
      expect(media.tuning, mediaTuningBefore);
      expect(voice.tuning, isNot(mediaTuningBefore));

      voice.release();
      media.release();
    });
  });

  group('media profile — stereo fidelity', () {
    test('left and right channels survive encode/decode distinctly', () {
      if (!available) return;
      final codec = OpusAudioCodec()
        ..setFormatProfile(AudioFormatProfile.media48kStereo)
        ..setProfile(OpusEncodeProfile.music);

      const n = 48000 * 20 ~/ 1000; // one 20ms frame @ 48kHz
      final left = _tone(n, 48000, [440]);
      final right = _tone(n, 48000, [1500]);
      final stereo = _interleave(left, right);

      Uint8List? packet;
      // A few frames so the encoder is past its first-frame ramp-up.
      for (var i = 0; i < 5; i++) {
        packet = codec.encode(stereo);
      }
      expect(packet, isNotNull);
      final result = codec.decode(packet!, 'peer', 4);
      expect(result, isNotNull);
      final (decodedLeft, decodedRight) = _deinterleave(result!.samples);

      // Decoded left must resemble source left far more than source right,
      // and vice versa — proof the channels weren't collapsed or swapped.
      final leftVsLeft = _correlation(decodedLeft, left);
      final leftVsRight = _correlation(decodedLeft, right);
      final rightVsRight = _correlation(decodedRight, right);
      final rightVsLeft = _correlation(decodedRight, left);

      expect(leftVsLeft, greaterThan(0.8));
      expect(rightVsRight, greaterThan(0.8));
      expect(leftVsLeft, greaterThan(leftVsRight));
      expect(rightVsRight, greaterThan(rightVsLeft));

      codec.release();
    });

    test('mono profile never manufactures a second channel', () {
      if (!available) return;
      final codec = OpusAudioCodec()
        ..setFormatProfile(AudioFormatProfile.media48kMono)
        ..setProfile(OpusEncodeProfile.music);

      final frame = _tone(
        AudioFormatProfile.media48kMono.frameSamples,
        48000,
        [600],
      );
      Uint8List? packet;
      for (var i = 0; i < 5; i++) {
        packet = codec.encode(frame);
      }
      expect(packet, isNotNull);
      final result = codec.decode(packet!, 'peer', 4);
      expect(result, isNotNull);
      // No interleaving to undo — exactly frameSamples, not frameSamples*2.
      expect(result!.samples.length, AudioFormatProfile.media48kMono.frameSamples);

      codec.release();
    });
  });

  group('media profile — signal integrity', () {
    test('decoded samples stay finite and within range across a long run', () {
      if (!available) return;
      final codec = OpusAudioCodec()
        ..setFormatProfile(AudioFormatProfile.media48kStereo)
        ..setProfile(OpusEncodeProfile.music);

      final frameSamples = AudioFormatProfile.media48kStereo.frameSamples;

      // A few thousand 20ms frames stands in for "several minutes" without
      // making the suite slow — same continuity intent, compressed in wall
      // time the same way MusicMixer's own drift tests are.
      const frameCount = 3000;
      for (var i = 0; i < frameCount; i++) {
        final left = _tone(frameSamples, 48000, [220, 880], start: i * frameSamples);
        final right = _tone(frameSamples, 48000, [330, 990], start: i * frameSamples);
        final packet = codec.encode(_interleave(left, right));
        expect(packet, isNotNull, reason: 'frame $i failed to encode');
        final result = codec.decode(packet!, 'peer', i);
        expect(result, isNotNull, reason: 'frame $i failed to decode');
        for (final s in result!.samples) {
          expect(s.isFinite, isTrue, reason: 'non-finite sample at frame $i');
          expect(s, inInclusiveRange(-1.0, 1.0), reason: 'clipped sample at frame $i');
        }
      }

      codec.release();
    });
  });

  group('media profile — bitrate policy', () {
    test('MediaOpusTuner output applies to a media-profile encoder', () {
      if (!available) return;
      final codec = OpusAudioCodec()
        ..setFormatProfile(AudioFormatProfile.media48kStereo)
        ..setProfile(OpusEncodeProfile.music);

      const tuner = MediaOpusTuner();
      final tuning = tuner.tune(const AudioLinkConditions());
      expect(() => codec.applyTuning(tuning), returnsNormally);
      expect(tuning.bitrate, greaterThanOrEqualTo(MediaOpusTuner.hdFloorBitrate));

      codec.release();
    });
  });
}
