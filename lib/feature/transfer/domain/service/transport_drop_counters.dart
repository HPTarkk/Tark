/// Tracks the wifi transport's three drop/block classes as both a
/// per-log-window count and a session-cumulative total, keeping the two
/// lifetimes independent.
///
/// The window counts are read and zeroed every ~15s by the diagnostic log
/// line ([takeWindow]); the totals are read every 2s by the link-quality
/// grader (via [staleEpochTotal] etc.), which diffs successive samples to get
/// a rate. The log line's reset cadence must never touch the totals — only an
/// actual session boundary should, via [reset] — or the grader sees a total
/// drop below its own last reading and computes a spurious negative delta.
/// This is the bug issue #27 tracks: the two counters used to share storage,
/// so [takeWindow]'s reset silently zeroed the totals too.
class TransportDropCounters {
  int _staleEpochWindow = 0;
  int _duplicateRouteWindow = 0;
  int _blockedWindow = 0;

  int _staleEpochTotal = 0;
  int _duplicateRouteTotal = 0;
  int _blockedTotal = 0;

  int get staleEpochTotal => _staleEpochTotal;
  int get duplicateRouteTotal => _duplicateRouteTotal;
  int get blockedTotal => _blockedTotal;

  void staleEpochDropped() {
    _staleEpochWindow++;
    _staleEpochTotal++;
  }

  void duplicateRouteDropped() {
    _duplicateRouteWindow++;
    _duplicateRouteTotal++;
  }

  void blocked() {
    _blockedWindow++;
    _blockedTotal++;
  }

  /// Reads and zeroes the per-log-window counts. Totals are untouched — this
  /// is exactly the operation that used to reset both together.
  TransportDropWindow takeWindow() {
    final window = TransportDropWindow(
      staleEpoch: _staleEpochWindow,
      duplicateRoute: _duplicateRouteWindow,
      blocked: _blockedWindow,
    );
    _staleEpochWindow = 0;
    _duplicateRouteWindow = 0;
    _blockedWindow = 0;
    return window;
  }

  /// The true session boundary: zeroes the window counts and the cumulative
  /// totals alike. Call only when the session itself is ending — a new
  /// [WalkieTalkieCubit] instance already starts its own diff baseline at
  /// [TransportStats.none], so this only has to make the transport's own
  /// counters agree with that fresh baseline.
  void reset() {
    _staleEpochWindow = 0;
    _duplicateRouteWindow = 0;
    _blockedWindow = 0;
    _staleEpochTotal = 0;
    _duplicateRouteTotal = 0;
    _blockedTotal = 0;
  }
}

/// One log line's worth of drop counts, taken and zeroed together by
/// [TransportDropCounters.takeWindow].
class TransportDropWindow {
  const TransportDropWindow({
    required this.staleEpoch,
    required this.duplicateRoute,
    required this.blocked,
  });

  final int staleEpoch;
  final int duplicateRoute;
  final int blocked;
}
