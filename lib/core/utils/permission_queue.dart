import 'dart:async';

/// Serializes runtime permission requests across the whole app.
///
/// Android allows exactly one in-flight `requestPermissions()` per activity.
/// A second one raised while the first dialog is showing is dropped by the
/// framework with:
///
///     W/Activity: Can request only one set of permissions at a time
///
/// and permission_handler never completes the Future belonging to the request
/// that was dropped — so that caller awaits forever. On a fresh install this
/// was reproducible: the Bluetooth flow and the audio engine each asked within
/// 21 ms of each other, and whichever lost the race left its awaiting code
/// (the walkie session's `start()`) hanging with no dialog and no error.
///
/// Requests queued here are run one at a time, so each dialog is raised only
/// after the previous one has been answered.
class PermissionQueue {
  PermissionQueue._();

  /// How long a queued request may hold the queue before later requests are
  /// let through anyway.
  ///
  /// Generous on purpose: a permission dialog is allowed to sit on screen for
  /// as long as the user ignores it, and cutting that short would fire the
  /// next dialog on top of it — the exact collision this class exists to
  /// prevent. This is only a backstop against a request that can never
  /// settle at all (the activity being recreated under a live dialog, say),
  /// so that one stuck caller cannot wedge every later request for the rest
  /// of the process's life.
  static const _kSlotTimeout = Duration(minutes: 2);

  static Future<void> _tail = Future<void>.value();

  /// Runs [request] once every previously queued request has settled.
  ///
  /// The returned Future mirrors [request]'s own result — including never
  /// completing, if the platform drops it. Only the queue slot is released
  /// early, never the caller's answer, so nobody is told "denied" for a
  /// dialog the user simply hasn't answered yet.
  static Future<T> run<T>(Future<T> Function() request) {
    final completer = Completer<T>();

    _tail = _tail.then((_) {
      final Future<T> pending;
      try {
        pending = request();
      } catch (e, s) {
        completer.completeError(e, s);
        return Future<void>.value();
      }

      pending.then(
        completer.complete,
        onError: (Object e, StackTrace s) => completer.completeError(e, s),
      );

      // Hold the queue until this request settles, but never past the
      // backstop above.
      return pending
          .then<void>((_) {}, onError: (Object _) {})
          .timeout(_kSlotTimeout, onTimeout: () {});
    }).catchError((Object _) {});

    return completer.future;
  }
}
