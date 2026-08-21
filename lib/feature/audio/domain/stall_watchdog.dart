/// Pure decision logic behind [AudioEngineImpl]'s stall watchdog — the timer
/// that restarts the audio engine when mic frames stop arriving.
///
/// Extracted so the fix described on `AudioEngineImpl._lastWatchdogAt` (a
/// screen-off nap must not itself read as a stall and trigger a restart of a
/// perfectly healthy engine) is testable on its own, without the native
/// `audio_io` FFI layer the engine is otherwise tangled with. No behavior
/// change from the inline version this replaces.
class StallWatchdog {
  const StallWatchdog({
    required this.stallTimeout,
    required this.minRestartInterval,
    required this.watchdogInterval,
    required this.watchdogJitter,
  });

  /// How long mic frames may stop arriving before this counts as a stall.
  final Duration stallTimeout;

  /// How long to wait after one restart before allowing another.
  final Duration minRestartInterval;

  /// The watchdog's own tick period, so a late tick can be told apart from a
  /// genuinely silent mic.
  final Duration watchdogInterval;

  /// Ordinary scheduling lateness for a timer sharing an isolate with
  /// rendering. Anything past this is the isolate not having run at all, not
  /// jitter.
  final Duration watchdogJitter;

  /// One watchdog tick.
  ///
  /// [lastWatchdogAt] is the previous call's `now`, so a tick that fires much
  /// later than [watchdogInterval] proves the isolate itself was suspended —
  /// backgrounded, Doze, a locked screen — for the gap, not that the mic went
  /// silent while awake. That gap is credited onto [lastInputAt] before
  /// judging a stall, precisely so a resume after a nap doesn't restart a
  /// healthy engine.
  StallCheckResult check({
    required DateTime now,
    required DateTime lastInputAt,
    required DateTime lastWatchdogAt,
    required DateTime lastRestartAt,
  }) {
    final sinceCheck = now.difference(lastWatchdogAt);
    final lateBy = sinceCheck - watchdogInterval;

    var creditedInputAt = lastInputAt;
    if (lateBy > watchdogJitter) {
      final credited = lastInputAt.add(lateBy);
      creditedInputAt = credited.isAfter(now) ? now : credited;
    }

    final stalled = now.difference(creditedInputAt) >= stallTimeout;
    final cooledDown = now.difference(lastRestartAt) >= minRestartInterval;

    return StallCheckResult(
      creditedInputAt: creditedInputAt,
      shouldRestart: stalled && cooledDown,
    );
  }
}

/// Outcome of one [StallWatchdog.check] tick.
class StallCheckResult {
  const StallCheckResult({
    required this.creditedInputAt,
    required this.shouldRestart,
  });

  /// The caller's next `lastInputAt` — unchanged unless the tick itself was
  /// late enough to credit a gap onto it.
  final DateTime creditedInputAt;

  /// Whether a genuine, cooled-down stall was found and the engine should be
  /// restarted now.
  final bool shouldRestart;
}
