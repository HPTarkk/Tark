/// Bookkeeping for a running music cast: whether capture has ever carried
/// audio, how long it has been silent, and whether the mixer's counters moved
/// since they were last logged.
///
/// Pure: callers pass `now` and do the logging, the media-session query and
/// the toast themselves.
class MusicCastWatch {
  MusicCastWatch({this.blockedAfter = const Duration(seconds: 8)});

  /// Level below which a capture chunk counts as silence. The same threshold
  /// the equalizer uses to decide it is flatlining, so what the log says and
  /// what the card shows can never disagree.
  static const double audibleLevel = 0.004;

  /// How long capture must be silent before another app claiming to be playing
  /// counts as this device refusing to hand over the audio.
  ///
  /// Generous on purpose: starting the cast before choosing a song is normal
  /// (the idle copy invites exactly that), and a cast must never be second-
  /// guessed for a pause between tracks.
  final Duration blockedAfter;

  /// Since when every captured chunk has been silent, or null if the last one
  /// carried audio.
  DateTime? _silentSince;

  /// Whether this cast has *ever* produced audible capture. A device that has
  /// managed it once is not the blocked case, whatever it does later.
  bool get everAudible => _everAudible;
  bool _everAudible = false;

  /// Whether the blocked-capture diagnosis has already been delivered, so it is
  /// said once per cast rather than every tick.
  bool _blockedReported = false;

  // Last reported mixer counters, so the health line stays quiet unless
  // something actually changed. Kept across casts, as they always were.
  int _lastDropouts = 0;
  int _lastTrims = 0;
  int _lastFloods = 0;

  /// A cast has just started capturing: silent until a chunk says otherwise.
  void started(DateTime now) {
    _silentSince = now;
    _everAudible = false;
  }

  /// A cast has ended, however it ended.
  void stopped() {
    _silentSince = null;
    _everAudible = false;
    _blockedReported = false;
  }

  /// One capture chunk arrived at [level] (see `MusicMixer.levelOf`).
  void noteChunk(double level, DateTime now) {
    if (level >= audibleLevel) {
      _silentSince = null;
      _everAudible = true;
    } else {
      _silentSince ??= now;
    }
  }

  /// Whether capture has been silent long enough, on a cast that has never
  /// been audible and has not been diagnosed yet, to be worth asking the
  /// system whether another app is playing.
  bool shouldSuspectBlocked(DateTime now) {
    if (_blockedReported || _everAudible) return false;
    final since = _silentSince;
    if (since == null) return false;
    return now.difference(since) >= blockedAfter;
  }

  /// The blocked-capture diagnosis was delivered for this cast.
  void markBlockedReported() => _blockedReported = true;

  /// Records the mixer's counters, returning whether any of them moved since
  /// the last call.
  bool countersMoved({
    required int dropouts,
    required int trims,
    required int floods,
  }) {
    if (dropouts == _lastDropouts &&
        trims == _lastTrims &&
        floods == _lastFloods) {
      return false;
    }
    _lastDropouts = dropouts;
    _lastTrims = trims;
    _lastFloods = floods;
    return true;
  }
}
