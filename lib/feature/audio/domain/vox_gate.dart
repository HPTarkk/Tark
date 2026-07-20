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
  bool advance(double rms, double threshold) {
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
