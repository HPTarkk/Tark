import 'analytics.dart';
import 'analytics_event.dart';

/// Bookkeeping for one pairing attempt, shared by every connect screen
/// (Bluetooth, hotspot, guest link).
///
/// The funnel it feeds is only trustworthy if every `pair_started` is
/// followed by exactly one `pair_connected` or `pair_failed`. Left to four
/// separate cubits with four separate `bool _reported` flags, that invariant
/// would survive about one refactor: a retry path that forgets to re-arm
/// inflates the failure count, a state stream that emits `connected` twice
/// double-counts the win, and either way the drop-off percentages quietly
/// stop meaning anything.
///
/// So the invariant lives here instead. [start] opens an attempt, the first
/// of [connected]/[failed] closes it, and everything after that is dropped
/// until the next [start].
class PairingAttempt {
  PairingAttempt(this._analytics, {required this.transport});

  final Analytics _analytics;
  final AnalyticsTransport transport;

  Stopwatch? _elapsed;
  PairRole? _role;

  /// True between [start] and whichever outcome closes the attempt.
  bool get isOpen => _elapsed != null;

  /// Opens an attempt. Calling it again while one is open restarts the
  /// clock rather than emitting a second `pair_started` — a user hammering
  /// "retry" is one attempt from the funnel's point of view.
  ///
  /// [role] is passed here rather than to the constructor because Bluetooth
  /// only learns which side it is when the user picks host or joiner.
  void start(PairRole role) {
    _role = role;
    if (isOpen) {
      _elapsed!.reset();
      return;
    }
    _elapsed = Stopwatch()..start();
    _analytics.track(
      AnalyticsEvent.pairStarted(transport: transport, role: role),
    );
  }

  void connected() {
    final elapsed = _elapsed;
    if (elapsed == null) return;
    _analytics.track(
      AnalyticsEvent.pairConnected(
        transport: transport,
        role: _role ?? PairRole.joiner,
        elapsed: elapsed.elapsed,
      ),
    );
    _close();
  }

  void failed(PairStage stage, PairFailure reason) {
    if (!isOpen) return;
    _analytics.track(
      AnalyticsEvent.pairFailed(
        transport: transport,
        role: _role ?? PairRole.joiner,
        stage: stage,
        reason: reason,
      ),
    );
    _close();
  }

  /// Closes an attempt without reporting anything — for a screen the user
  /// leaves while a connection is still in flight and might yet succeed in
  /// the background (Bluetooth's cold-start auto-reconnect does exactly
  /// this). Guessing "failed" there would invent failures that never
  /// happened.
  void abandon() => _close();

  void _close() {
    _elapsed = null;
    _role = null;
  }
}
