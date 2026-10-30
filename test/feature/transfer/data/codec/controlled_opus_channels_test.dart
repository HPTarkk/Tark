import 'dart:ffi';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:tark/feature/transfer/data/codec/controlled_opus_ffi.dart';

/// Real libopus round trips for the controlled codec. libopus counts
/// `frame_size` per channel; the stereo Shared Music stream used to hand it
/// the interleaved length, encoding every 20 ms frame as 40 ms with a stale
/// second half — a seam at every frame boundary, heard as crackling.
void main() {
  final path = Platform.environment['OPUS_TEST_LIBRARY'] ?? 'libopus.so.0';
  DynamicLibrary? library;
  try {
    library = DynamicLibrary.open(path);
  } catch (_) {}
  final skip = library == null
      ? 'libopus is not available on this host'
      : false;

  const rate = 48000;
  const frame = 960; // 20 ms per channel
  const audio = 2049; // OPUS_APPLICATION_AUDIO

  /// [frames] of a continuous tone per channel, interleaved, as PCM16.
  List<Int16List> tone(int channels, int frames) {
    final out = <Int16List>[];
    var n = 0;
    for (var f = 0; f < frames; f++) {
      final pcm = Int16List(frame * channels);
      for (var i = 0; i < frame; i++, n++) {
        for (var c = 0; c < channels; c++) {
          final hz = c == 0 ? 440.0 : 660.0;
          pcm[i * channels + c] = (0.5 * 32767 * sin(2 * pi * hz * n / rate))
              .round();
        }
      }
      out.add(pcm);
    }
    return out;
  }

  double largestStep(List<double> s, int channels, int channel) {
    var worst = 0.0;
    for (var i = channel + channels; i < s.length; i += channels) {
      worst = max(worst, (s[i] - s[i - channels]).abs());
    }
    return worst;
  }

  for (final channels in [1, 2]) {
    test('$channels-channel frames round trip whole and seamless', () {
      final encoder = tryCreateControlledOpusEncoder(
        library: library,
        sampleRate: rate,
        channels: channels,
        application: audio,
      )!;
      final decoder = tryCreateControlledOpusDecoder(
        library: library,
        sampleRate: rate,
        channels: channels,
      )!;
      addTearDown(encoder.destroy);
      addTearDown(decoder.destroy);

      final played = <double>[];
      for (final pcm in tone(channels, 50)) {
        final decoded = decoder.decode(encoder.encode(pcm));
        expect(decoded, hasLength(frame * channels));
        played.addAll(decoded);
      }
      // Past the codec's start-up, a 440/660 Hz tone at half scale moves at
      // most ~0.04 per sample; a seam jumps far more.
      final settled = played.sublist(frame * channels * 3);
      for (var c = 0; c < channels; c++) {
        expect(largestStep(settled, channels, c), lessThan(0.08));
      }
    }, skip: skip);
  }

  test('a stereo FEC recovery is one whole interleaved frame', () {
    final encoder = tryCreateControlledOpusEncoder(
      library: library,
      sampleRate: rate,
      channels: 2,
      application: audio,
    )!;
    final decoder = tryCreateControlledOpusDecoder(
      library: library,
      sampleRate: rate,
      channels: 2,
    )!;
    addTearDown(encoder.destroy);
    addTearDown(decoder.destroy);
    final frames = tone(2, 3);
    decoder.decode(encoder.encode(frames[0]));
    encoder.encode(frames[1]); // lost
    final next = encoder.encode(frames[2]);
    expect(decoder.decodeFec(next, frame), hasLength(frame * 2));
    expect(decoder.decode(next), hasLength(frame * 2));
  }, skip: skip);
}
