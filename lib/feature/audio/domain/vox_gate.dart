import 'dart:collection';

/// VOX shaping shared by the walkie and guest sessions. A raw per-frame RMS
/// gate is what made transmission sound choppy: the instant a frame dipped
/// below threshold (every gap between words, every soft syllable) TX cut
/// out, chopping word endings, and the first frame of speech was likewise
/// lost because the gate only opened AFTER the onset frame that tripped it.
/// Two counter-measures:
///  * hangover — once voice is detected, keep transmitting for a while
///    after the level drops, so natural pauses don't slice the stream;
///  * pre-roll — while idle, keep the last few frames; when the gate
///    opens, send them first so the word onset that opened it is heard.
class VoxGate {
  VoxGate({this.hangoverFrames = 35, this.prerollFrames = 3});

  /// 35 × 20 ms = 700 ms of keep-open after the level drops.
  final int hangoverFrames;

  /// 3 × 20 ms = 60 ms of onset context flushed when the gate opens.
  final int prerollFrames;

  final ListQueue<List<double>> _preroll = ListQueue();
  int _hangover = 0;

  /// Advances the gate one frame and reports whether it is open afterwards.
  ///
  /// A threshold of zero means VOX off, not "VOX at its most sensitive": the
  /// slider behind it reads HOW LOUD TO START and sits at 0%, which is a
  /// promise that nothing the mic hands over is ever held back. The strict
  /// `rms > threshold` below cannot keep that promise on its own, because a
  /// frame of exact digital silence is not greater than zero — and exact
  /// digital silence is precisely what a phone whose platform noise
  /// suppressor is doing its job hands over between words.
  ///
  /// Measured on a Galaxy S8+ (hardware AEC/NS attached to the capture
  /// session): 301 of 800 frames in a 15s window came back as 0.0, the
  /// hangover ran out 700 ms into each pause, and the channel unkeyed and
  /// re-keyed five times in that window — five PTT chirps, five haptic
  /// bumps, and a listener hearing the speech chopped into pieces. The
  /// second phone in the same session, whose mic keeps a live noise floor,
  /// never gated once. So this reads as "that one phone mutes itself every
  /// few seconds", which is exactly how it was reported.
  bool advance(double rms, double threshold) {
    if (threshold <= 0) {
      // Held open rather than returned early: an unmute mid-pause must not
      // find a stale hangover that closes the gate a frame later.
      _hangover = hangoverFrames;
      return true;
    }
    if (rms > threshold) {
      _hangover = hangoverFrames;
    } else if (_hangover > 0) {
      _hangover--;
    }
    return _hangover > 0;
  }

  /// Buffer a frame while not transmitting, keeping only the newest
  /// [prerollFrames] frames.
  void bufferWhileClosed(List<double> samples) {
    _preroll.addLast(samples);
    while (_preroll.length > prerollFrames) {
      _preroll.removeFirst();
    }
  }

  /// Returns the buffered onset frames (oldest first) and clears the buffer.
  /// Callers flush these to the transport when transmission starts and
  /// simply discard them otherwise.
  List<List<double>> drainPreroll() {
    final drained = List<List<double>>.of(_preroll);
    _preroll.clear();
    return drained;
  }
}
