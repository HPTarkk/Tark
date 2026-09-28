import 'package:flutter/widgets.dart';

import '../utils/logger.dart';

/// Records where the user goes in the app: every page, sheet and dialog that
/// opens or closes, the in-page tabs they switch between, and taps on the few
/// buttons that start or end something (Start, Invite, Scan, Join, Leave, the
/// transport picker).
///
/// Everything goes through [Logger.diagnostic], so it lands in the same
/// `.tarklog` as the lifecycle, socket and audio lines and never leaves the
/// phone unless the user exports it. Read together, a report like "the room
/// broke after I tapped Invite" can be followed step by step, and the lines
/// are regular enough to mine later:
///
///     ui: open SettingsPage from LandingPage
///     ui: tap Start on RoomLobby
///     ui: tab hotspot on WifiHotspotPage
///     ui: close SettingsPage after 12.4s, back to LandingPage
///
/// Names come from [RouteSettings.name]: go_router sets it to the route name
/// (see AppRoutes), and every sheet and dialog passes its own. A route without
/// one is logged by its kind (`dialog`, `sheet`, `page`) rather than skipped,
/// so a newly added sheet still shows up, just less precisely.
class ScreenLog extends NavigatorObserver {
  /// When each route came on screen, for the time spent on it at close.
  static final Expando<DateTime> _openedAt = Expando<DateTime>('openedAt');

  /// The screen the user is on now, used to say where a [tap] or [tab]
  /// happened. Tracks the most recent route that opened or was returned to.
  static String _current = 'none';

  static String get current => _current;

  /// A tap on one of the key buttons. [button] is a short stable name
  /// ("Start", "Invite", "Leave"), not the translated label, so the log reads
  /// the same whatever language the app is in.
  static void tap(String button) =>
      Logger.diagnostic('ui: tap $button on $_current');

  /// A switch between tabs or steps inside one screen, which the navigator
  /// never sees.
  static void tab(String tab) => Logger.diagnostic('ui: tab $tab on $_current');

  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) {
    _opened(route, previousRoute);
  }

  @override
  void didReplace({Route<dynamic>? newRoute, Route<dynamic>? oldRoute}) {
    if (oldRoute != null) _closed(oldRoute, null);
    if (newRoute != null) _opened(newRoute, null);
  }

  @override
  void didPop(Route<dynamic> route, Route<dynamic>? previousRoute) {
    _closed(route, previousRoute);
  }

  @override
  void didRemove(Route<dynamic> route, Route<dynamic>? previousRoute) {
    _closed(route, null);
  }

  void _opened(Route<dynamic> route, Route<dynamic>? from) {
    _openedAt[route] = DateTime.now();
    final name = nameOf(route);
    _current = name;
    Logger.diagnostic(
      from == null ? 'ui: open $name' : 'ui: open $name from ${nameOf(from)}',
    );
  }

  void _closed(Route<dynamic> route, Route<dynamic>? backTo) {
    final name = nameOf(route);
    final openedAt = _openedAt[route];
    final spent = openedAt == null
        ? ''
        : ' after ${_seconds(DateTime.now().difference(openedAt))}s';
    if (backTo != null) _current = nameOf(backTo);
    Logger.diagnostic(
      backTo == null
          ? 'ui: close $name$spent'
          : 'ui: close $name$spent, back to ${nameOf(backTo)}',
    );
  }

  /// The route's own name, or its kind when it has none.
  @visibleForTesting
  static String nameOf(Route<dynamic> route) {
    final name = route.settings.name;
    if (name != null && name.isNotEmpty) return name;
    return switch (route) {
      PopupRoute() when route.runtimeType.toString().contains('Sheet') =>
        'sheet',
      PopupRoute() => 'dialog',
      _ => 'page',
    };
  }

  static String _seconds(Duration d) =>
      (d.inMilliseconds / 1000).toStringAsFixed(1);

  @visibleForTesting
  static void debugReset() => _current = 'none';
}
