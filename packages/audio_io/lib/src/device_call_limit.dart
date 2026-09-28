import 'dart:async';

/// Where audio_io reports things an app would want in its field logs. The
/// package has no logger of its own, so the app plugs its own in here.
abstract final class AudioIoDiagnostics {
  static void Function(String message)? sink;

  static void report(String message) => sink?.call(message);
}

/// Waits at most [limit] for a native device call running on a helper
/// isolate.
///
/// A device call that never returns is not hypothetical: after half an hour
/// in the background a Galaxy S8+ (Android 9) reopened its device for a route
/// change and the call never came back. Every later start and stop queued
/// behind it, so the mic and the speaker stayed dead and "Restart mic" did
/// nothing until the app was killed.
///
/// On timeout this returns [onTimeout]'s value and gives up on [call]. The
/// helper isolate stays parked where it is; if [call] does finish later, its
/// result goes to [onLate] so a device that came up too late can still be
/// torn down.
Future<T> limitDeviceCall<T>(
  Future<T> call, {
  required Duration limit,
  required T Function() onTimeout,
  void Function(T late)? onLate,
}) {
  var timedOut = false;
  call.then<void>(
    (value) {
      if (timedOut) onLate?.call(value);
    },
    onError: (Object _) {},
  );
  return call.timeout(
    limit,
    onTimeout: () {
      timedOut = true;
      return onTimeout();
    },
  );
}
