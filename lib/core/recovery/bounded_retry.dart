import 'dart:async';

import '../utils/logger.dart';

/// How far along a bounded retry cycle is, in terms of what the user should
/// be told.
///
/// The progression is deliberately gentle: most failures here are transient
/// (a radio still settling, a host that isn't up yet), and showing an error
/// card for something that fixes itself two seconds later teaches people to
/// distrust the app. So the first attempts look like an ordinary connect, and
/// only a wait long enough to read as a hang admits that it's retrying.
enum RetryPhase {
  /// Nothing running.
  idle,

  /// Early attempts. The UI shows a plain "Connecting…" — no error styling,
  /// no counter, nothing to alarm anyone.
  working,

  /// Still automatic, but it has now been going long enough that saying
  /// nothing would feel frozen. The UI softens to "Still trying…".
  stillTrying,

  /// Every automatic attempt is spent. This is the only phase that shows the
  /// user fix options — by now the problem is real and needs a human.
  exhausted,

  /// It worked.
  succeeded,
}

/// Thrown from a [BoundedRetry] body to end the cycle at once, because
/// retrying cannot possibly help.
///
/// The distinction matters more than it looks. "Turn your tethering off" and
/// "the radio was busy" both arrive as a failed start, but hammering the first
/// one four times only delays the user by ten seconds before telling them
/// something they could have acted on immediately. Aborting lands straight on
/// [RetryPhase.exhausted] — the phase that shows fixes — which is exactly
/// where a user-fixable failure belongs.
class RetryAbort implements Exception {
  const RetryAbort();
}

/// Runs an operation up to [maxAttempts] times, spacing the attempts out and
/// reporting progress as a [RetryPhase] the UI can render directly.
///
/// This exists so that "try a few times before bothering the user" is one
/// behaviour with one implementation, rather than each screen inventing its
/// own timers and attempt counters — which is how the hotspot host and the
/// manual Bluetooth connect ended up with none at all.
class BoundedRetry {
  /// Total automatic attempts, including the first. Four is the point where
  /// a genuinely transient failure has almost certainly cleared, and a real
  /// one has proven it isn't going anywhere.
  final int maxAttempts;

  /// Attempts to get through before the phase softens to
  /// [RetryPhase.stillTrying].
  final int honestAfter;

  /// Wait before the (1-based) attempt that follows a failure.
  final Duration Function(int attempt) backoff;

  /// For logs — which flow this retry belongs to.
  final String name;

  BoundedRetry({
    required this.name,
    this.maxAttempts = 4,
    this.honestAfter = 2,
    Duration Function(int attempt)? backoff,
  }) : backoff = backoff ?? _defaultBackoff;

  /// 1.5s → 3s → 5s. Short enough that four attempts fit inside the patience
  /// of someone staring at the screen, long enough for a radio to settle.
  static Duration _defaultBackoff(int attempt) =>
      Duration(milliseconds: (1500 * attempt).clamp(1500, 5000));

  final _phases = StreamController<RetryPhase>.broadcast();
  RetryPhase _phase = RetryPhase.idle;
  int _attempt = 0;

  /// Bumped by [cancel] and [dispose] so a cycle sleeping between attempts
  /// abandons itself instead of resuming into a screen that has moved on.
  int _generation = 0;
  bool _disposed = false;

  Stream<RetryPhase> get phases => _phases.stream;
  RetryPhase get phase => _phase;

  /// 1-based attempt currently in flight (0 when idle).
  int get attempt => _attempt;

  /// True while attempts are still being made automatically — the UI should
  /// stay calm and NOT offer fixes yet.
  bool get isWorking =>
      _phase == RetryPhase.working || _phase == RetryPhase.stillTrying;

  /// Runs [body] until it returns true or the attempts run out.
  ///
  /// [body] receives the 1-based attempt number and must return whether it
  /// succeeded; a throw counts as a failure, so callers don't have to wrap
  /// their own platform calls. Returns true if any attempt succeeded.
  Future<bool> run(Future<bool> Function(int attempt) body) async {
    final gen = ++_generation;
    _attempt = 0;

    for (var i = 1; i <= maxAttempts; i++) {
      if (_disposed || _generation != gen) return false;
      _attempt = i;
      _emit(i <= honestAfter ? RetryPhase.working : RetryPhase.stillTrying);

      var ok = false;
      try {
        ok = await body(i);
      } on RetryAbort {
        Logger.log('$name: attempt $i/$maxAttempts hit a failure retrying cannot fix');
        if (_disposed || _generation != gen) return false;
        _attempt = 0;
        _emit(RetryPhase.exhausted);
        return false;
      } catch (e) {
        // A throwing attempt is just a failed attempt — the whole point of
        // this helper is that the caller doesn't have to think about it.
        Logger.log('$name: attempt $i/$maxAttempts threw: $e');
      }
      if (_disposed || _generation != gen) return false;
      if (ok) {
        _attempt = 0;
        _emit(RetryPhase.succeeded);
        return true;
      }

      Logger.log('$name: attempt $i/$maxAttempts failed');
      if (i == maxAttempts) break;
      if (!await _sleep(backoff(i), gen)) return false;
    }

    if (_disposed || _generation != gen) return false;
    _attempt = 0;
    _emit(RetryPhase.exhausted);
    return false;
  }

  /// Sliced so a cancel lands promptly instead of waiting out the backoff.
  /// Returns false if the cycle was abandoned while sleeping.
  Future<bool> _sleep(Duration total, int gen) async {
    const slice = Duration(milliseconds: 150);
    var left = total;
    while (left > Duration.zero) {
      if (_disposed || _generation != gen) return false;
      await Future<void>.delayed(left < slice ? left : slice);
      left -= slice;
    }
    return !_disposed && _generation == gen;
  }

  /// Abandons any cycle in flight and goes quiet. Used when the user takes
  /// over manually, or navigates away.
  void cancel() {
    _generation++;
    _attempt = 0;
    _emit(RetryPhase.idle);
  }

  /// Resets to idle so a fresh [run] starts from a clean "Connecting…" —
  /// what a manual "Try again" tap should feel like.
  void reset() => cancel();

  void _emit(RetryPhase phase) {
    if (_disposed || _phase == phase) return;
    _phase = phase;
    if (!_phases.isClosed) _phases.add(phase);
  }

  void dispose() {
    _disposed = true;
    _generation++;
    unawaited(_phases.close());
  }
}
