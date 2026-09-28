import 'dart:async';

import 'package:flutter/widgets.dart';

import '../utils/logger.dart';
import 'log_detail.dart';

/// Records where the user goes and what they do in the app, as far as the
/// chosen [LogDetail] allows.
///
/// At [LogDetail.standard], the default, it writes nothing, so the log is
/// what it always was. [LogDetail.screens] adds every page, sheet and dialog
/// that opens or closes, the in-page tabs switched between, and taps on the
/// buttons that start or end something (Start, Invite, Join, Leave, the
/// transport picker). [LogDetail.everything] adds every tap anywhere (see
/// `TapLog`) and every settings change.
///
/// Everything goes through [Logger.diagnostic], so it lands in the same
/// `.tarklog` as the lifecycle, socket and audio lines and never leaves the
/// phone unless the user exports it. The lines are regular enough to mine:
///
///     ui: open SettingsPage from LandingPage
///     ui: tap Start on RoomListPage
///     ui: tab hotspot on WifiHotspotPage
///     ui: setting hd_voice_enabled = false
///     ui: close SettingsPage after 12.4s, back to LandingPage
///
/// Names come from [RouteSettings.name]: go_router sets it to the route name
/// (see AppRoutes), and every sheet and dialog passes its own. A route without
/// one is logged by its kind (`dialog`, `sheet`, `page`) rather than skipped,
/// so a newly added sheet still shows up, just less precisely.
class ScreenLog extends NavigatorObserver {
  /// Set from preferences in `main()` and by the Log level control.
  static LogDetail detail = LogDetail.fallback;

  static bool get logsScreens => detail.index >= LogDetail.screens.index;
  static bool get logsEverything => detail == LogDetail.everything;

  /// When each route came on screen, for the time spent on it at close.
  static final Expando<DateTime> _openedAt = Expando<DateTime>('openedAt');

  /// The screen the user is on now, used to say where a [tap] or [tab]
  /// happened. Tracked at every level, so raising the level mid-session
  /// names the right screen straight away.
  static String _current = 'none';

  static String get current => _current;

  /// A tap on one of the key buttons. [button] is a short stable name
  /// ("Start", "Invite", "Leave"), not the translated label, so the log reads
  /// the same whatever language the app is in.
  static void tap(String button) {
    if (logsScreens) Logger.diagnostic('ui: tap $button on $_current');
  }

  /// A switch between tabs or steps inside one screen, which the navigator
  /// never sees.
  static void tab(String tab) {
    if (logsScreens) Logger.diagnostic('ui: tab $tab on $_current');
  }

  /// Any tap, described by `TapLog`. Only at [LogDetail.everything].
  static void anyTap(String description) {
    if (logsEverything) {
      Logger.diagnostic('ui: touch $description on $_current');
    }
  }

  /// How long a setting has to stay put before it is logged. Sliders write
  /// on every frame of a drag; this keeps a drag to the one value it ended on.
  static const settleDelay = Duration(milliseconds: 700);

  static final Map<String, Timer> _pendingSettings = {};

  /// A settings change, logged once it has settled (see [settleDelay]).
  /// Only at [LogDetail.everything].
  static void setting(String key, Object? value) {
    if (!logsEverything) return;
    _pendingSettings.remove(key)?.cancel();
    _pendingSettings[key] = Timer(settleDelay, () {
      _pendingSettings.remove(key);
      Logger.diagnostic('ui: setting $key = $value');
    });
  }

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
    if (!logsScreens) return;
    Logger.diagnostic(
      from == null ? 'ui: open $name' : 'ui: open $name from ${nameOf(from)}',
    );
  }

  void _closed(Route<dynamic> route, Route<dynamic>? backTo) {
    if (backTo != null) _current = nameOf(backTo);
    if (!logsScreens) return;
    final name = nameOf(route);
    final openedAt = _openedAt[route];
    final spent = openedAt == null
        ? ''
        : ' after ${_seconds(DateTime.now().difference(openedAt))}s';
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
      PopupRoute() when route.runtimeType.toString().contains('Menu') => 'menu',
      PopupRoute() => 'dialog',
      _ => 'page',
    };
  }

  static String _seconds(Duration d) =>
      (d.inMilliseconds / 1000).toStringAsFixed(1);

  @visibleForTesting
  static void debugReset() {
    _current = 'none';
    detail = LogDetail.fallback;
    for (final timer in _pendingSettings.values) {
      timer.cancel();
    }
    _pendingSettings.clear();
  }
}
