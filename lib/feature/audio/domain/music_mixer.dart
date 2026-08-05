import 'dart:math';
import 'dart:typed_data';

import 'float64_fifo.dart';

/// Re-cuts captured system audio (~100 ms chunks on its own clock) to the
/// mic's 20 ms frame grid and mixes it on top of the (possibly silent)
/// voice frame.
///
/// ## Why this needs a prebuffer
///
/// The two sides of this queue run on *different clocks*. Capture is filled
/// by Android's playback-capture stream in ~100 ms chunks, delivered over an
/// EventChannel onto the UI isolate; it is drained 20 ms at a time by
/// [mix], driven by the microphone's own callback. Nothing synchronises them.
///
/// Left to itself the depth therefore sawtooths: it jumps ~100 ms when a
/// chunk lands and falls 20 ms per mic frame until the next one does — which
/// means it reaches **zero** just before every single chunk arrives. At that
/// point any delivery jitter at all (and the delivery hop shares an isolate
/// with rendering, so a dropped frame or two is routine) leaves [mix] with
/// nothing to mix, and the music silently drops out for a frame. At ~10
/// chunks a second that is continuous stuttering, and it does not depend on
/// the network in any way — which is why it reproduced on every test.
///
/// [prefillSamples] fixes the geometry: music is withheld until that much has
/// accumulated, so the sawtooth's *bottom* sits a prefill above empty instead
/// of on it, and ordinary jitter can no longer reach zero. It costs exactly
/// that much one-off delay between the host's own speaker and what peers
/// hear, which for a music cast is unnoticeable.
///
/// ## Why it also needs drift handling
///
/// Independent clocks do not just jitter, they drift — and the mic side is a
/// nominal rate fed through a fixed-ratio resampler, so it is not even exactly
/// 16 kHz to begin with. Drift in one direction empties the queue (handled by
/// re-priming above); drift in the other fills it until it pins at
/// [maxQueuedSamples] and every subsequent chunk hard-splices the head. Both
/// ends are therefore ramped rather than stepped, and the slow side is walked
/// back with a small trim at [highWaterSamples] long before the cap turns into
/// an audible cut — the same shape the receive-side jitter buffer uses.
class MusicMixer {
  MusicMixer({
    this.maxQueuedSamples = 16000,
    int sampleRate = 16000,
    int prefillMs = kDefaultPrefillMs,
    int highWaterMs = kDefaultHighWaterMs,
    int fadeMs = kDefaultFadeMs,
  }) : prefillSamples = sampleRate * prefillMs ~/ 1000,
       highWaterSamples = sampleRate * highWaterMs ~/ 1000,
       _trimStepSamples = sampleRate * 10 ~/ 1000,
       // At least one sample, which is the same as no ramp: a zero-length
       // ramp has nothing to divide by, and a one-sample ramp is unity.
       _fadeSamples = max(1, sampleRate * fadeMs ~/ 1000);

  /// Cushion held before music starts flowing, and re-accumulated after any
  /// dropout. Must exceed one capture chunk (~100 ms) plus realistic delivery
  /// jitter, or it is not a cushion at all — see the class comment.
  static const int kDefaultPrefillMs = 200;

  /// Depth above which the queue is trimmed back toward the prefill. Well
  /// clear of the prefill so ordinary sawtooth motion never triggers it, and
  /// well under [maxQueuedSamples] so drift is corrected in 10 ms steps rather
  /// than by the cap amputating a whole chunk at once.
  static const int kDefaultHighWaterMs = 450;

  /// Ramp applied at every discontinuity. Long enough to turn a step into a
  /// slope, short enough that no music is perceptibly lost to it.
  static const int kDefaultFadeMs = 3;

  /// Cap on buffered capture audio — 1 s at 16 kHz. The capture and mic
  /// clocks drift, and a runaway queue would turn into pure latency. Only a
  /// memory backstop now: [highWaterSamples] bounds latency well before this.
  final int maxQueuedSamples;

  /// Samples that must accumulate before (re)starting the music.
  final int prefillSamples;

  /// Depth at which drift is walked back down.
  final int highWaterSamples;

  final int _trimStepSamples;

  /// Short ramp applied at every discontinuity — start, dropout, and trim
  /// splice — so the music never steps to or from a level. A step is a click;
  /// 3 ms of ramp is inaudible.
  final int _fadeSamples;

  // Unboxed ring buffer — a ListQueue<double> boxed every captured sample
  // (16k allocations/sec while casting), steady GC pressure for nothing.
  final Float64Fifo _queue = Float64Fifo();

  /// True while accumulating toward [prefillSamples]. Starts set, so the very
  /// first frames pass voice through untouched rather than mixing a
  /// half-empty queue.
  bool _priming = true;

  /// Remaining samples of ramp-in owed after a (re)start or a trim.
  int _fadeInRemaining = 0;

  // Diagnostics. Counted rather than logged per event: at 50 frames a second
  // a log line per dropout would be the loudest thing in the file.
  int _dropouts = 0;
  int _trims = 0;
  int _overflowDrops = 0;

  /// How many times the queue has run dry mid-cast. Non-zero means the
  /// cushion is losing to capture jitter or clock drift.
  int get dropouts => _dropouts;

  /// How many times drift has been walked back from [highWaterSamples].
  int get trims => _trims;

  /// How many times the hard [maxQueuedSamples] cap has had to cut. Should
  /// stay at zero — the trim exists to keep it there.
  int get overflowDrops => _overflowDrops;

  /// Samples currently buffered. Exposed for diagnostics and tests.
  int get queuedSamples => _queue.length;

  /// Whether music is currently withheld while the cushion refills.
  bool get isPriming => _priming;

  /// Queue a captured chunk, dropping the oldest samples over the cap.
  void addChunk(List<double> chunk) {
    _queue.addAll(chunk);
    if (_queue.length > maxQueuedSamples) {
      _overflowDrops++;
      _queue.discardFirst(_queue.length - maxQueuedSamples);
      // The head just moved discontinuously; ramp back in from the new one.
      _fadeInRemaining = _fadeSamples;
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
  /// Falls back to the voice-only samples while the cushion is filling (music
  /// paused, capture-protected app, or recovering from a dropout).
  ///
  /// Cubic taper, not the raw slider value: peers hear the capture at full
  /// level regardless of the host's media volume (playback capture taps
  /// pre-volume audio), so this multiply is their ONLY volume control — and
  /// linear amplitude is nearly inaudible across most of the slider's
  /// travel (0.5 is just -6 dB). Cubing maps the slider onto roughly the
  /// same loudness curve the host's own speaker follows via system volume
  /// steps (0.5 → -18 dB, 0 → silence), so both sides respond alike.
  List<double> mix(List<double> voice, double sliderGain) {
    final mixed = Float64List(voice.length);
    for (var i = 0; i < voice.length; i++) {
      mixed[i] = voice[i];
    }

    if (_priming) {
      // Not enough banked yet — voice only. Mixing what little is there would
      // produce exactly the fragmentary music this cushion exists to prevent.
      if (_queue.length < prefillSamples) return mixed;
      _priming = false;
      _fadeInRemaining = _fadeSamples;
    }

    // Drift correction, one small step per frame. Small enough to be masked by
    // the ramp below, and repeated across frames it still catches any drift a
    // real clock pair can produce.
    if (_queue.length > highWaterSamples) {
      final excess = _queue.length - prefillSamples;
      _queue.discardFirst(min(excess, _trimStepSamples));
      _fadeInRemaining = _fadeSamples;
      _trims++;
    }

    final gain = sliderGain * sliderGain * sliderGain;
    final take = min(voice.length, _queue.length);
    // Running dry inside a frame: emit what there is, but ramp it out over the
    // tail so the music decays to silence instead of stepping to it, then go
    // back to priming so the next start is cushioned rather than immediate.
    final starving = take < voice.length;
    final fadeOutFrom = starving ? max(0, take - _fadeSamples) : take;

    for (var i = 0; i < take; i++) {
      var music = _queue[i] * gain;
      if (_fadeInRemaining > 0) {
        final done = _fadeSamples - _fadeInRemaining;
        music *= min(1.0, (done + 1) / _fadeSamples);
        _fadeInRemaining--;
      }
      if (i >= fadeOutFrom) {
        music *= (take - i) / (take - fadeOutFrom);
      }
      mixed[i] = (voice[i] + music).clamp(-1.0, 1.0);
    }
    _queue.discardFirst(take);

    if (starving) {
      _dropouts++;
      _priming = true;
      _fadeInRemaining = 0;
    }
    return mixed;
  }

  void clear() {
    _queue.clear();
    _priming = true;
    _fadeInRemaining = 0;
  }
}
