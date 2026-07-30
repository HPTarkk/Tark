import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:home_widget/home_widget.dart';
import 'package:injectable/injectable.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../l10n/app_localizations.dart';
import '../locale/locale_service.dart';
import '../theme/theme_service.dart';
import '../utils/logger.dart';
import 'home_widget_keys.dart';
import 'home_widget_launch.dart';
import 'home_widget_service.dart';
import 'home_widget_snapshot.dart';

/// Only Android and iOS have home-screen widgets; the plugin's method channel
/// isn't implemented anywhere else, so every call would throw
/// [MissingPluginException] on desktop and the guest web build.
bool get _supported =>
    !kIsWeb &&
    (defaultTargetPlatform == TargetPlatform.android ||
        defaultTargetPlatform == TargetPlatform.iOS);

@LazySingleton(as: HomeWidgetService)
class HomeWidgetServiceImpl implements HomeWidgetService {
  HomeWidgetServiceImpl(this._prefs);

  final SharedPreferences _prefs;
  final _launchController = StreamController<HomeWidgetLaunch>.broadcast();
  StreamSubscription<Uri?>? _clickSub;

  /// Last payload written, used to skip redundant redraws. The walkie cubit
  /// emits on every audio frame that flips a flag, which is far more often
  /// than a home screen can usefully repaint.
  Map<String, Object>? _lastPayload;

  /// The raw facts behind [_lastPayload], kept so [refresh] can re-render
  /// them after a language or theme change without the caller having to
  /// know what the session was doing.
  HomeWidgetSnapshot? _lastSnapshot;

  DateTime? _lastWriteAt;

  /// Comfortably inside the 90s TTL the native side demotes a stale "live"
  /// state after, so an unchanging session always refreshes in time.
  static const _heartbeat = Duration(seconds: 30);

  @override
  Stream<HomeWidgetLaunch> get launches => _launchController.stream;

  @override
  Future<void> initialize() async {
    if (!_supported) return;
    try {
      // iOS-only in effect, but harmless on Android: without the App Group
      // the extension reads an empty UserDefaults and renders placeholders.
      await HomeWidget.setAppGroupId(HomeWidgetIds.appGroup);
      _clickSub = HomeWidget.widgetClicked.listen((uri) {
        final launch = HomeWidgetLaunch.parse(uri);
        if (launch != null) _launchController.add(launch);
      });
    } catch (e) {
      // A widget that won't initialize must never take the app down with
      // it — the whole feature is a convenience shortcut.
      Logger.log('HomeWidget init failed: $e');
    }
  }

  @override
  Future<HomeWidgetLaunch?> takeInitialLaunch() async {
    if (!_supported) return null;
    try {
      final launch = HomeWidgetLaunch.parse(
        await HomeWidget.initiallyLaunchedFromHomeWidget(),
      );
      if (launch == null) return null;
      // The platform hands back the same launch intent on every subsequent
      // engine start (it is never cleared, and MainActivity is singleTop),
      // so a tap is only ever acted on once — see [HomeWidgetLaunch].
      if (_prefs.getString(HomeWidgetKeys.consumedLaunchNonce) ==
          launch.nonce) {
        return null;
      }
      await _prefs.setString(
        HomeWidgetKeys.consumedLaunchNonce,
        launch.nonce,
      );
      return launch;
    } catch (e) {
      Logger.log('HomeWidget initial launch read failed: $e');
      return null;
    }
  }

  @override
  Future<void> publish(HomeWidgetSnapshot snapshot) async {
    if (!_supported) return;
    final payload = _render(snapshot);
    // updatedAt always differs, so compare everything else — otherwise the
    // dedupe below never fires.
    _lastSnapshot = snapshot;
    // Drop redundant redraws, but never go quiet for longer than the native
    // side's staleness TTL. A live session that simply isn't changing (nobody
    // talking, roster steady) emits no new payload, and without this the
    // timestamp would stop advancing and both widgets would demote a
    // perfectly healthy channel to "idle" while it was still running.
    final now = DateTime.now();
    final quiet = _lastWriteAt == null || now.difference(_lastWriteAt!) >= _heartbeat;
    if (!quiet &&
        _lastPayload != null &&
        _sameExceptTimestamp(_lastPayload!, payload)) {
      return;
    }
    _lastPayload = payload;
    _lastWriteAt = now;
    try {
      for (final entry in payload.entries) {
        await HomeWidget.saveWidgetData(entry.key, entry.value);
      }
      await HomeWidget.updateWidget(
        qualifiedAndroidName: HomeWidgetIds.androidProvider,
        iOSName: HomeWidgetIds.iOSWidgetKind,
      );
    } catch (e) {
      Logger.log('HomeWidget publish failed: $e');
    }
  }

  @override
  Future<bool> canPin() async {
    if (!_supported) return false;
    try {
      return await HomeWidget.isRequestPinWidgetSupported() ?? false;
    } catch (e) {
      Logger.log('HomeWidget pin support check failed: $e');
      return false;
    }
  }

  @override
  Future<void> requestPin() async {
    if (!_supported) return;
    try {
      await HomeWidget.requestPinWidget(
        qualifiedAndroidName: HomeWidgetIds.androidProvider,
      );
    } catch (e) {
      Logger.log('HomeWidget pin request failed: $e');
    }
  }

  @override
  Future<void> refresh() async {
    final snapshot = _lastSnapshot;
    if (snapshot == null) return;
    // _render reads LocaleService/ThemeService fresh, so re-running it with
    // the same facts is exactly what picks the new language or theme up. The
    // payload genuinely differs now, so the dedupe in publish lets it through.
    await publish(snapshot);
  }

  bool _sameExceptTimestamp(Map<String, Object> a, Map<String, Object> b) {
    if (a.length != b.length) return false;
    for (final key in a.keys) {
      if (key == HomeWidgetKeys.updatedAt) continue;
      if (a[key] != b[key]) return false;
    }
    return true;
  }

  /// Turns raw session facts into exactly what the native widgets draw.
  ///
  /// Localization happens here rather than natively so the fa/en ARB files
  /// stay the single source of copy — [LocaleService] and [ThemeService] are
  /// process-wide statics, so this needs no BuildContext.
  Map<String, Object> _render(HomeWidgetSnapshot snapshot) {
    final l = lookupAppLocalizations(LocaleService.currentLocale);
    final session = snapshot.session;

    final status = switch (session) {
      HomeWidgetSession.setup => l.widget_status_setup,
      HomeWidgetSession.idle => l.widget_status_idle,
      HomeWidgetSession.connecting => l.connecting,
      HomeWidgetSession.listening => l.monitoring,
      HomeWidgetSession.receiving => l.widget_status_receiving(snapshot.talker),
      HomeWidgetSession.onAir => l.mic_on_air,
      HomeWidgetSession.muted => l.mic_muted_title,
      HomeWidgetSession.reconnecting => l.link_reconnecting,
      HomeWidgetSession.down => l.link_down,
    };

    final action = switch (session) {
      HomeWidgetSession.setup => l.widget_action_setup,
      HomeWidgetSession.idle => l.widget_action_go,
      // Live: the main button stops being a launcher, so it reads as a way
      // back into the running session rather than a second "go live".
      _ => l.widget_action_open,
    };

    final peers = switch (session.isLive) {
      // Peer count is meaningless outside a session — the last one is from
      // a channel that's no longer running.
      false => '',
      true when snapshot.peerCount == 0 => l.widget_peers_alone,
      true => l.widget_peers(snapshot.peerCount),
    };

    // Keyed off TransferMode.key strings rather than the enum (see
    // HomeWidgetSnapshot.modeKey). The wifi fallback mirrors
    // TransferMode.fromKey, which treats anything unrecognised as wifi too.
    final modeLabel = switch (snapshot.modeKey) {
      'bluetooth' => l.transport_bluetooth,
      'hotspot' => l.transport_hotspot,
      'guest' => l.transport_guest,
      _ => l.transport_wifi,
    };

    return {
      HomeWidgetKeys.session: session.name,
      HomeWidgetKeys.mode: snapshot.modeKey,
      HomeWidgetKeys.callsign: snapshot.callsign,
      HomeWidgetKeys.peerCount: snapshot.peerCount,
      HomeWidgetKeys.talker: snapshot.talker,
      HomeWidgetKeys.modeLabel: modeLabel,
      HomeWidgetKeys.statusLine: status,
      HomeWidgetKeys.actionLabel: action,
      HomeWidgetKeys.peersLabel: peers,
      HomeWidgetKeys.muteLabel: session == HomeWidgetSession.muted
          ? l.mic_action_unmute
          : l.mic_action_mute,
      HomeWidgetKeys.endLabel: l.widget_end,
      HomeWidgetKeys.isRtl: LocaleService.currentLocale.languageCode == 'fa',
      HomeWidgetKeys.isLight: ThemeService.isLight,
      HomeWidgetKeys.updatedAt: DateTime.now().millisecondsSinceEpoch,
    };
  }

  @override
  @disposeMethod
  void dispose() {
    _clickSub?.cancel();
    _launchController.close();
  }
}
