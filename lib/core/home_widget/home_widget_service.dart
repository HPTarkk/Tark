import 'home_widget_launch.dart';
import 'home_widget_snapshot.dart';

/// Publishes app state to the Android/iOS home-screen widgets and reports
/// taps coming back the other way.
///
/// The widgets are pure renderers: they can't run Dart, so everything they
/// show is whatever was last published here. That makes [publish] the only
/// thing standing between a killed session and a home screen that still
/// claims to be LIVE — see [HomeWidgetKeys.updatedAt] for the staleness
/// backstop when the process dies before it can publish.
abstract interface class HomeWidgetService {
  /// Wires the tap callbacks. Safe to call on platforms without widgets
  /// (desktop, web) — it no-ops rather than throwing.
  Future<void> initialize();

  /// Renders [snapshot] into the shared store and asks both platforms to
  /// redraw. Cheap enough to call on every state change; consecutive
  /// identical snapshots are dropped.
  Future<void> publish(HomeWidgetSnapshot snapshot);

  /// Re-renders and re-publishes the last snapshot.
  ///
  /// Needed because the widget shows *rendered* state, not raw state: the
  /// display strings are localized and the colors themed at publish time. A
  /// language or theme change therefore doesn't reach the widget on its own —
  /// nothing about the session changed, so nothing republishes, and the home
  /// screen keeps the strings from before the switch until the next session
  /// event. No-ops if nothing has been published yet.
  Future<void> refresh();

  /// Whether the launcher can add the widget on the user's behalf.
  ///
  /// Android 8+ with a launcher that implements pinning — most do, but Samsung
  /// and some OEM launchers historically didn't, so this is a runtime question,
  /// not a version check. Always false on iOS: there is no equivalent API, and
  /// the user has to long-press the home screen themselves.
  Future<bool> canPin();

  /// Asks the launcher to add the widget. The launcher shows its own
  /// confirmation, so there's nothing to report back — the user may well
  /// decline, and there's no callback that says which.
  Future<void> requestPin();

  /// Taps that arrive while the app is already running.
  Stream<HomeWidgetLaunch> get launches;

  /// The tap that cold-started the app, or null. One-shot: the underlying
  /// platform intent is cleared so a later relaunch can't replay it.
  Future<HomeWidgetLaunch?> takeInitialLaunch();

  void dispose();
}
