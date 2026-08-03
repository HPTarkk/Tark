import 'analytics_event.dart';

/// Product analytics sink.
///
/// Deliberately three methods wide: everything expressive lives in
/// [AnalyticsEvent]'s named constructors, so a call site can't invent an
/// event token, misspell an attribute key, or send an unbucketed value.
///
/// Implementations must be safe to call unconditionally — [track] before
/// [start], or on a platform with no SDK, is a no-op rather than an error.
/// Nothing in the app is allowed to branch on whether analytics is on.
abstract interface class Analytics {
  /// Starts the SDK if the user hasn't opted out and the platform supports
  /// it. Never throws, never blocks startup on a network call.
  Future<void> start();

  /// Records one event. Silently dropped when the SDK isn't running.
  void track(AnalyticsEvent event);

  /// Applies the user's opt-out choice, taking effect immediately: enabling
  /// starts the SDK if this launch skipped it, disabling stops all uploads.
  Future<void> setEnabled(bool enabled);
}
