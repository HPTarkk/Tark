/// Telegram-style exponential reconnect backoff.
///
/// The first retry waits [initial], each subsequent one multiplies by [factor]
/// (4s → 8s → 16s → …), capped at [max]. [reset] returns to the initial delay
/// and must be called once a connection is re-established, so the *next* drop
/// starts backing off from scratch instead of from the last (long) delay.
///
/// Deliberately dependency-free and side-effect-free (no timers) so it stays
/// unit-testable and the caller keeps control of how it sleeps — the transports
/// slice their waits into short chunks so a session teardown can abort promptly.
class ExponentialBackoff {
  ExponentialBackoff({
    this.initial = const Duration(seconds: 4),
    this.factor = 2,
    this.max = const Duration(seconds: 64),
  }) : assert(factor >= 1),
       assert(initial > Duration.zero),
       _current = initial;

  final Duration initial;
  final int factor;
  final Duration max;

  Duration _current;

  /// The delay to wait for the current attempt, then advances toward [max].
  /// The first call returns [initial].
  Duration next() {
    final delay = _current;
    final grown = _current * factor;
    _current = grown > max ? max : grown;
    return delay;
  }

  /// The delay the next [next] call will return, without advancing.
  Duration peek() => _current;

  /// Back to square one — call after a successful (re)connection.
  void reset() => _current = initial;
}
