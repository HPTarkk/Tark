import 'home_widget_keys.dart';

/// What a tap on the home-screen widget asked the app to do.
enum HomeWidgetIntent {
  /// Main button: land in the last-used mode and connect, skipping Landing.
  /// Arriving is all it takes to be live — [WalkieTalkieState] starts
  /// un-muted, so VOX opens the mic as soon as the channel is up.
  goLive,

  /// Stops at Landing instead. Backs the mode badge, so there is always a
  /// way in from the widget that cannot start transmitting.
  open,

  /// First-run widget: send the user through onboarding.
  setup,

  /// Gear affordance.
  settings,
}

/// A widget tap, as encoded in the URI the native widgets fire at the app:
/// `tark://widget/<intent>?n=<nonce>`.
///
/// The nonce is not decoration. `initiallyLaunchedFromHomeWidget()` just
/// reads `activity.intent` and never clears it, and MainActivity is
/// `singleTop` — so after one widget launch, that intent stays attached to
/// the task. Every later engine start would re-read the same tap and act on
/// it again. Since [goLive] lands on a live mic, a replayed tap could open
/// the mic on a launch the user made from the app icon.
///
/// The guard is one-shot consumption rather than a time window: the URI is
/// built when the widget *renders*, not when it is tapped, so any freshness
/// deadline would reject taps on a widget that had been sitting idle. See
/// `HomeWidgetServiceImpl.takeInitialLaunch`.
class HomeWidgetLaunch {
  const HomeWidgetLaunch(this.intent, this.nonce);

  final HomeWidgetIntent intent;

  /// Identifies this particular rendering of the widget. Native side uses
  /// the publish timestamp, so it changes every time the app republishes.
  final String nonce;

  /// The URI format the native widgets build by hand — Android in
  /// `WidgetActions.kt`, iOS in `TarkWidget.swift`. Kept here so the three
  /// copies have one written-down source.
  static String uriFor(HomeWidgetIntent intent, String nonce) =>
      '${HomeWidgetIds.uriScheme}://widget/${intent.name}?n=$nonce';

  /// Returns null for anything that isn't a widget tap: a null or non-widget
  /// URI, an unknown intent, or a missing nonce.
  static HomeWidgetLaunch? parse(Uri? uri) {
    if (uri == null) return null;
    if (uri.scheme != HomeWidgetIds.uriScheme) return null;
    if (uri.host != 'widget') return null;

    final name = uri.pathSegments.isEmpty ? '' : uri.pathSegments.first;
    final intent = HomeWidgetIntent.values
        .where((i) => i.name == name)
        .firstOrNull;
    if (intent == null) return null;

    final nonce = uri.queryParameters['n'] ?? '';
    if (nonce.isEmpty) return null;

    return HomeWidgetLaunch(intent, nonce);
  }
}
