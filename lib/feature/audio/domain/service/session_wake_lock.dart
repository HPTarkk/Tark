/// Holds the CPU + Wi-Fi awake for the duration of a session so audio and
/// the transport survive the screen going off (the motorcycle case).
///
/// Only the session-scoped start/stop pair lives here — the battery
/// optimization / MIUI queries on the static [SessionKeepAlive] bridge are
/// widget-only concerns and are deliberately not part of this interface.
abstract interface class SessionWakeLock {
  /// [usesMicrophone] must be false when starting BEFORE mic capture begins
  /// (a microphone-typed foreground service is rejected on Android 14+
  /// without an active mic — see SessionKeepAlive.start).
  Future<void> start({bool usesMicrophone = true});

  Future<void> stop();
}
