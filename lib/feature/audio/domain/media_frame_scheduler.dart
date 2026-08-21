import 'dart:async';
import 'dart:math';

import '../../../core/audio/audio_format_profile.dart';
import 'float64_fifo.dart';
import 'media_channel_converter.dart';

/// Sends Shared Music as its own transport stream, on its own clock — see
/// #30. Where [MusicMixer] re-cut captured audio onto the *microphone's*
/// 20 ms frame grid (so music could only ever travel mixed into a voice
/// packet, keyed by whether the mic callback ran at all), this schedules
/// itself: a [Timer.periodic] at the negotiated media profile's own frame
/// duration, completely decoupled from VOX, self-mute, or whether the mic
/// callback fires at all. Muting or VOX-gating voice therefore has no effect
/// on this — media keeps transmitting on its own clock, which is precisely
/// the safety invariant #30 requires ("media survives self-mute/VOX
/// silence").
///
/// Fed from `SystemAudioCapture.hdFrames` via [addChunk] — genuinely
/// interleaved stereo, ~100 ms chunks, on its own delivery clock (an
/// EventChannel hop sharing the UI isolate with everything else). Not
/// imported directly: this is a domain class and the capture bridge is
/// data-layer, so the cubit is the one wiring point that knows about both,
/// same separation [MusicMixer] already keeps.
///
/// ## Why this needs the same cushion [MusicMixer] does
///
/// The capture chunk clock (~100 ms) and this scheduler's own drain clock
/// (the negotiated frame duration, 20 ms) are still two independent clocks —
/// swapping "the mic callback" for "this timer" does not remove the
/// mismatch, it just moves which clock is on the other side of it. The same
/// prefill/high-water/flood cushion [MusicMixer] uses (see that class's own
/// doc for the full reasoning) applies unchanged: withhold sending until a
/// cushion has banked, trim small excess in steps so drift never reaches a
/// hard cut, and drop a whole backlog in one splice (rather than seaming
/// every frame for a second) when delivery has genuinely stalled and
/// resumed — e.g. the app backgrounding.
///
/// Unlike [MusicMixer], there is no base track to mix onto and nothing else
/// this must emit every tick: a starved tick simply sends nothing that
/// round, which is the "stale media frames dropped rather than accumulating
/// latency" behaviour #30 asks for, for free.
class MediaFrameScheduler {
  MediaFrameScheduler({
    required this.profile,
    required this.sendFrame,
    int captureSampleRateHz = kDefaultCaptureSampleRateHz,
    this.captureChannels = kDefaultCaptureChannels,
    int prefillMs = kDefaultPrefillMs,
    int highWaterMs = kDefaultHighWaterMs,
    int floodMs = kDefaultFloodMs,
  }) : assert(
         profile.kind == AudioProfileKind.media,
         'MediaFrameScheduler only ever carries a media profile',
       ),
       _captureSamplesPerMs = captureSampleRateHz * captureChannels ~/ 1000,
       prefillSamples =
           captureSampleRateHz * captureChannels * prefillMs ~/ 1000,
       highWaterSamples =
           captureSampleRateHz * captureChannels * highWaterMs ~/ 1000,
       floodSamples = captureSampleRateHz * captureChannels * floodMs ~/ 1000,
       _trimStepSamples = captureSampleRateHz * captureChannels * 10 ~/ 1000;

  /// The negotiated media profile this instance sends — see
  /// `TransferRepository.negotiatedMediaFormat`. Fixed for the scheduler's
  /// lifetime: a profile change means tearing this instance down and
  /// building a new one, same as a format change rebuilds the Opus encoder
  /// underneath it.
  final AudioFormatProfile profile;

  /// Hands one ready wire frame to the transport — e.g.
  /// `(samples) => transferRepository.sendMedia(samples, senderName)`.
  /// Errors are the transport's problem to log; this class does not retry or
  /// interpret the result.
  final void Function(List<double> samples) sendFrame;

  /// Channel count of every chunk [addChunk] receives —
  /// `SystemAudioCapture.hdFrames`' fixed contract (genuinely interleaved
  /// stereo; see `SystemAudioCaptureService.CAPTURE_RATE`). Not read off
  /// [AudioFormatProfile.media48kStereo] to avoid this domain class
  /// depending on the data-layer capture bridge — the sample rate default
  /// below matches it for the same reason.
  static const kDefaultCaptureSampleRateHz = 48000;
  static const kDefaultCaptureChannels = 2;
  final int captureChannels;

  /// Same defaults as [MusicMixer] — the capture-side jitter these absorb is
  /// the same native ~100 ms chunk cadence either way.
  static const int kDefaultPrefillMs = 200;
  static const int kDefaultHighWaterMs = 450;
  static const int kDefaultFloodMs = 900;

  final int _captureSamplesPerMs;

  /// Cap on buffered capture audio — 1 s of interleaved capture. Only a
  /// memory backstop; [highWaterSamples] bounds latency well before this.
  int get maxQueuedSamples => _captureSamplesPerMs * 1000;

  final int prefillSamples;
  final int highWaterSamples;
  final int floodSamples;
  final int _trimStepSamples;

  final Float64Fifo _queue = Float64Fifo();
  bool _priming = true;
  Timer? _timer;

  int _dropouts = 0;
  int _trims = 0;
  int _floods = 0;
  int _overflowDrops = 0;

  /// How many ticks found less than one whole frame banked — capture
  /// stalling or a link too slow to matter, since nothing is sent for that
  /// tick and the cushion re-primes.
  int get dropouts => _dropouts;

  /// How many times drift has been walked back from [highWaterSamples].
  int get trims => _trims;

  /// How many times a whole backlog has been dropped at [floodSamples] —
  /// non-zero means delivery stalled and resumed (normally backgrounding),
  /// not that the clocks merely drifted.
  int get floods => _floods;

  /// How many times the hard [maxQueuedSamples] cap has had to cut. Should
  /// stay at zero — the trim exists to keep it there.
  int get overflowDrops => _overflowDrops;

  /// Samples currently buffered (interleaved capture channels). Exposed for
  /// diagnostics and tests.
  int get queuedSamples => _queue.length;

  /// Whether sending is currently withheld while the cushion refills.
  bool get isPriming => _priming;

  /// Whether the scheduler's own timer is running.
  bool get isRunning => _timer != null;

  /// Queues a captured chunk, dropping the oldest samples over the cap.
  void addChunk(List<double> interleavedChunk) {
    _queue.addAll(interleavedChunk);
    if (_queue.length > maxQueuedSamples) {
      _overflowDrops++;
      _queue.discardFirst(_queue.length - maxQueuedSamples);
    }
  }

  /// Starts the send clock. Idempotent — calling it again just restarts the
  /// timer on the current profile's cadence, which callers do freely rather
  /// than tracking whether it is already running.
  void start() {
    _timer?.cancel();
    _timer = Timer.periodic(
      Duration(milliseconds: profile.frameDurationMs),
      (_) => _tick(),
    );
  }

  /// Stops the send clock without discarding buffered audio — a caller that
  /// wants a clean cushion on the next [start] should also call [clear].
  void stop() {
    _timer?.cancel();
    _timer = null;
  }

  void _tick() {
    if (_priming) {
      // Not enough banked yet — send nothing this round. Sending whatever
      // trickle exists would be exactly the fragmentary music the cushion
      // exists to prevent.
      if (_queue.length < prefillSamples) return;
      _priming = false;
    }

    // A backlog rather than drift: stepping it down would seam every frame
    // for the best part of a second, so take it in one splice.
    if (_queue.length > floodSamples) {
      _queue.discardFirst(_queue.length - prefillSamples);
      _floods++;
    } else if (_queue.length > highWaterSamples) {
      // Drift correction, one small step per tick.
      final excess = _queue.length - prefillSamples;
      _queue.discardFirst(min(excess, _trimStepSamples));
      _trims++;
    }

    final frameInterleaved = profile.frameSamples * captureChannels;
    if (_queue.length < frameInterleaved) {
      // Genuinely starved: nothing fragmentary goes out, and the next tick
      // waits out a fresh cushion rather than resuming on a trickle.
      _dropouts++;
      _priming = true;
      return;
    }

    final raw = _queue.takeFirst(frameInterleaved);
    // Only a real stereo->mono downmix ever applies here — a captureChannels
    // of 1 is already whatever it is, and manufacturing stereo from mono
    // capture is exactly what [MediaChannelConverter]'s doc rules out.
    final samples = (captureChannels == 2 && profile.channels == 1)
        ? MediaChannelConverter.downmixToMono(raw)
        : raw;
    sendFrame(samples);
  }

  /// Discards buffered audio and returns to priming — call on a music-cast
  /// (re)start or after backgrounding, same as `MusicMixer.clear()`.
  void clear() {
    _queue.clear();
    _priming = true;
  }

  /// Stops the clock and discards buffered audio.
  void dispose() {
    stop();
    _queue.clear();
  }
}
