/// What the channel did with each mic frame, counted over a log window.
///
/// The capture line in AudioEngineImpl says the mic produced frames; this
/// says what the channel then did with them. Between the two sits VOX,
/// self-mute and the online gate, and any of the three can silently swallow
/// a whole session's speech — which reads on the other phone as "I could not
/// hear you at all" and reads here, without these counters, as nothing.
///
/// Plain integer bumps on the audio path; [takeWindow] turns them into the
/// counts half of one log line and starts the next window.
class TransmitCounters {
  TransmitCounters({this.interval = const Duration(seconds: 15)});

  /// The shortest window worth a line.
  final Duration interval;

  int _seen = 0;
  int _sent = 0;
  int _gated = 0;
  int _prerollFlushes = 0;
  int _prerollFrames = 0;
  DateTime _windowStart = DateTime.fromMillisecondsSinceEpoch(0);

  /// A mic frame arrived.
  void frameSeen() => _seen++;

  /// A frame went out on the wire.
  void frameSent() => _sent++;

  /// A frame was held back by the gate.
  void frameGated() => _gated++;

  /// The gate opened and its pre-roll was flushed — [frames] of it.
  void prerollFlushed(int frames) {
    _prerollFlushes++;
    _prerollFrames += frames;
  }

  /// The counts since the last window, as
  /// `"Ns window — frames=… sent=… gated=… preroll=…/…bursts"`, or null when
  /// there is nothing worth saying: the window is still shorter than
  /// [interval] (counters keep running), or it is longer than a minute or saw
  /// no frames at all (counters start over — a gap that long is a suspended
  /// process, not a transmit decision).
  ///
  /// Deliberately the *ratio* of frames arriving to frames sent: that is what
  /// separates "the mic was dead" from "VOX never opened" from "we were muted
  /// the whole time", three identical symptoms with different fixes.
  String? takeWindow(DateTime now) {
    final window = now.difference(_windowStart);
    if (window < interval) return null;
    _windowStart = now;
    String? line;
    if (window.inSeconds <= 60 && _seen != 0) {
      line =
          '${window.inSeconds}s window — frames=$_seen '
          'sent=$_sent gated=$_gated '
          'preroll=$_prerollFrames/${_prerollFlushes}bursts';
    }
    _seen = 0;
    _sent = 0;
    _gated = 0;
    _prerollFlushes = 0;
    _prerollFrames = 0;
    return line;
  }
}
