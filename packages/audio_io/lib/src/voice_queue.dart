import 'dart:typed_data';

/// The native received-voice queue the audio callback plays from
/// (`src/voice_playout.h`).
///
/// Only the Dart side's half: writing samples, setting the depth, and reading
/// counters. When playback starts, trimming, jumping back to live and running
/// dry are all decided natively, in the callback, against the device's real
/// pull timing — which is the point of having it.
abstract interface class VoiceQueue {
  /// Appends samples; returns how many fit.
  int write(Float64List samples);

  /// Appends [count] samples of silence; returns how many fit.
  int writeSilence(int count);

  /// Depth, in output-rate samples, to fill to before playing and trim back
  /// toward. The device's own pull size is added natively.
  set targetFrames(int frames);

  /// Drops everything queued, at the callback's next pull.
  void reset();

  /// Samples queued and not yet played.
  int get queuedFrames;

  /// Whether the callback is currently playing (not filling or idle).
  bool get isPlaying;

  /// Cumulative counters since the device started.
  int get underruns;
  int get starvedFrames;
  int get playedFrames;
  int get trims;
  int get jumps;

  /// Largest number of frames the device has asked for in one callback.
  int get deviceBurstFrames;
}
