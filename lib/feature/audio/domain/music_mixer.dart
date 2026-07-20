import 'dart:math';
import 'dart:typed_data';

import 'float64_fifo.dart';

/// Re-cuts captured system audio (~100 ms chunks on its own clock) to the
/// mic's 20 ms frame grid and mixes it on top of the (possibly silent)
/// voice frame.
class MusicMixer {
  MusicMixer({this.maxQueuedSamples = 16000});

  /// Cap on buffered capture audio — 1 s at 16 kHz. The capture and mic
  /// clocks drift, and a runaway queue would turn into pure latency.
  final int maxQueuedSamples;

  // Unboxed ring buffer — a ListQueue<double> boxed every captured sample
  // (16k allocations/sec while casting), steady GC pressure for nothing.
  final Float64Fifo _queue = Float64Fifo();

  /// Queue a captured chunk, dropping the oldest samples over the cap.
  void addChunk(List<double> chunk) {
    _queue.addAll(chunk);
    if (_queue.length > maxQueuedSamples) {
      _queue.discardFirst(_queue.length - maxQueuedSamples);
    }
  }

  /// RMS of a captured chunk, for the music-cast equalizer (0 when empty).
  static double levelOf(List<double> chunk) {
    if (chunk.isEmpty) return 0;
    var sum = 0.0;
    for (final sample in chunk) {
      sum += sample * sample;
    }
    return sqrt(sum / chunk.length);
  }

  /// Adds up to one frame's worth of queued system audio on top of [voice].
  /// Falls back to the voice-only samples when the queue runs dry (music
  /// paused, capture-protected app).
  ///
  /// Cubic taper, not the raw slider value: peers hear the capture at full
  /// level regardless of the host's media volume (playback capture taps
  /// pre-volume audio), so this multiply is their ONLY volume control — and
  /// linear amplitude is nearly inaudible across most of the slider's
  /// travel (0.5 is just -6 dB). Cubing maps the slider onto roughly the
  /// same loudness curve the host's own speaker follows via system volume
  /// steps (0.5 → -18 dB, 0 → silence), so both sides respond alike.
  List<double> mix(List<double> voice, double sliderGain) {
    final gain = sliderGain * sliderGain * sliderGain;
    final mixed = Float64List(voice.length);
    final take = min(voice.length, _queue.length);
    for (var i = 0; i < take; i++) {
      mixed[i] = (voice[i] + _queue[i] * gain).clamp(-1.0, 1.0);
    }
    _queue.discardFirst(take);
    for (var i = take; i < voice.length; i++) {
      mixed[i] = voice[i];
    }
    return mixed;
  }

  void clear() => _queue.clear();
}
