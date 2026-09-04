import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:injectable/injectable.dart';

import '../../../../core/utils/logger.dart';
import '../../domain/entity/hotspot_credentials.dart';
import '../../domain/service/hotspot_control.dart';

/// Android host side of the hotspot bridge: drives `WifiManager
/// .startLocalOnlyHotspot` over the native `tark/hotspot` channel
/// (see HotspotHandler.kt).
///
/// The reservation is held open natively across navigation to the walkie
/// screen — [stop] is what tears it down (when the user leaves the session).
@LazySingleton(as: HotspotHost)
class WifiHotspotController implements HotspotHost {
  static const _channel = MethodChannel('tark/hotspot');
  static const _events = EventChannel('tark/hotspot/events');

  bool get isSupported => Platform.isAndroid;

  bool _hosting = false;

  /// Kept for as long as an access point of ours is up, and only then. The
  /// alternative — a flag set by [start] and cleared by [stop] — is right up
  /// until the OS takes the hotspot down on its own, which is the one case
  /// this app already knows happens (radio conflict, Doze, an STA reconnect
  /// stealing the single radio) and the one case where a stale `true` sends
  /// somebody into a channel over an access point that is no longer on the
  /// air.
  StreamSubscription<void>? _teardownWatch;

  @override
  bool get isHosting => _hosting;

  /// Fires when the OS tears the hotspot down on its own — a radio conflict, an
  /// STA reconnect stealing the single radio, Doze, etc. — as opposed to our
  /// own [stop]. Lets a host recover instead of silently going dead. Never
  /// emits for an app-initiated teardown (see HotspotHandler.expectingStop).
  @override
  Stream<void> get onStopped => _events.receiveBroadcastStream().where((event) {
    if (event is! Map || event['event'] != 'stopped') return false;
    final generation = event['generation'] ?? 'unknown';
    final reason = event['reason'] ?? 'os_callback';
    Logger.diagnostic(
      'hotspot: stopped reason=$reason generation=$generation',
    );
    return true;
  }).map<void>((_) {});

  /// Starts a local-only Wi-Fi hotspot and returns its credentials. Throws a
  /// [PlatformException] (code `tethering_on`, `location_off`,
  /// `permission_denied`, `no_channel`, `failed`, …) or [UnsupportedError] off
  /// Android; callers surface that as an error card.
  @override
  Future<HotspotCredentials> start() async {
    if (!isSupported) {
      throw UnsupportedError('Hotspot hosting requires Android.');
    }
    Logger.diagnostic('hotspot: start requested');
    try {
      final result =
          await _channel.invokeMapMethod<String, dynamic>('start') ?? const {};
      final ssid = (result['ssid'] as String?) ?? '';
      final passphrase = (result['passphrase'] as String?) ?? '';
      final security = (result['security'] as String?) ?? 'WPA';
      if (ssid.isEmpty) {
        Logger.diagnostic('hotspot: start failed reason=no_credentials');
        throw PlatformException(
          code: 'no_credentials',
          message: 'Hotspot started without an SSID',
        );
      }
      // Never log SSID/passphrase: they are current transport credentials,
      // not diagnostic identity. The security class is safe and sufficient
      // to correlate this transition with the native callback timeline.
      Logger.diagnostic('hotspot: started security=$security');
      _hosting = true;
      _watchTeardown();
      return HotspotCredentials(
        ssid: ssid,
        passphrase: passphrase,
        security: security,
      );
    } on PlatformException catch (e) {
      Logger.diagnostic('hotspot: start failed reason=${e.code}');
      rethrow;
    }
  }

  /// Subscribes once, on the way up, rather than in the constructor: the
  /// event channel's platform side is only asked to start listening when
  /// something actually listens, and a device that never hosts should not be
  /// the reason it does.
  void _watchTeardown() {
    _teardownWatch ??= onStopped.listen(
      (_) => _hosting = false,
      onError: (Object _) => _hosting = false,
      onDone: () => _hosting = false,
    );
  }

  void _stopWatchingTeardown() {
    unawaited(_teardownWatch?.cancel() ?? Future<void>.value());
    _teardownWatch = null;
  }

  @override
  Future<void> stop() async {
    _hosting = false;
    _stopWatchingTeardown();
    if (!isSupported) return;
    Logger.diagnostic('hotspot: stop requested');
    try {
      await _channel.invokeMethod<void>('stop');
      Logger.diagnostic('hotspot: stop completed');
    } on PlatformException catch (e) {
      Logger.diagnostic('hotspot: stop failed reason=${e.code}');
      // Best-effort teardown — the reservation also closes with the activity.
    }
  }

  @override
  Future<void> openFixSettings(String errorCode) async {
    if (!isSupported) return;
    final method = switch (errorCode) {
      'location_off' => 'openLocationSettings',
      'tethering_on' => 'openTetherSettings',
      _ => null,
    };
    if (method == null) return;
    try {
      await _channel.invokeMethod<void>(method);
    } on PlatformException {
      // Some OEM builds have no such screen — nothing else to try.
    }
  }

  @override
  Future<HotspotWifiAdvice> wifiAdvice() async {
    if (!isSupported) return HotspotWifiAdvice.none;
    try {
      final r =
          await _channel.invokeMapMethod<String, dynamic>('wifiAdvice') ??
          const {};
      return HotspotWifiAdvice(
        wifiEnabled: r['wifiEnabled'] as bool? ?? false,
        // Defaults to *concurrent* when the value is missing, which is the
        // quiet answer. A channel that didn't respond is not evidence of a
        // problem, and a note that appears because a read failed teaches the
        // user to ignore the one that appears because it didn't.
        concurrent: r['concurrent'] as bool? ?? true,
        canPanel: r['canPanel'] as bool? ?? false,
      );
    } on PlatformException catch (e) {
      Logger.log('Hotspot wifi advice unavailable: $e');
      return HotspotWifiAdvice.none;
    } on MissingPluginException {
      return HotspotWifiAdvice.none;
    }
  }

  @override
  Future<bool> openWifiPanel() async {
    if (!isSupported) return false;
    try {
      return await _channel.invokeMethod<bool>('openWifiPanel') ?? false;
    } on PlatformException catch (e) {
      Logger.log('Hotspot wifi panel failed: $e');
      return false;
    }
  }
}

/// iOS join side: asks CoreLocation-free `NEHotspotConfiguration` to join the
/// Android host's network programmatically (see HotspotJoinHandler.swift).
///
/// This only works when the "Hotspot Configuration" capability is enabled in
/// Xcode; otherwise the native side reports failure and the UI falls back to
/// showing the SSID/password for a manual join. [join] therefore never
/// throws — it returns whether the auto-join succeeded.
@injectable
class NeHotspotJoiner implements HotspotJoiner {
  static const _channel = MethodChannel('tark/hotspot_join');

  @override
  Future<HotspotJoinResult> join(HotspotCredentials credentials) async {
    try {
      final ok = await _channel.invokeMethod<bool>('join', {
        'ssid': credentials.ssid,
        'passphrase': credentials.passphrase,
      });
      return ok == true
          ? HotspotJoinResult.joined
          : HotspotJoinResult.declined;
    } on PlatformException catch (e) {
      Logger.log('iOS hotspot join failed: ${e.code} ${e.message}');
      return HotspotJoinResult.declined;
    } on MissingPluginException {
      return HotspotJoinResult.declined;
    }
  }

  /// iOS has no app-facing Wi-Fi switch at all, and NEHotspotConfiguration
  /// reports a radio-off join as an ordinary failure — so this side never
  /// reaches [HotspotJoinResult.wifiOff] and has nothing to offer here.
  @override
  Future<bool> enableWifi() async => false;

  /// iOS doesn't gate Wi-Fi on a Location toggle, so this side never reports
  /// [HotspotJoinResult.locationOff] either.
  @override
  Future<void> openLocationSettings() async {}

  /// iOS keeps a joined network as the system's Wi-Fi and has no per-process
  /// network binding to take — nothing to pin.
  @override
  Future<bool> bindToCurrentWifi() async => false;

  /// NEHotspotConfiguration joins are the system's to keep; iOS drops ours
  /// when the app is uninstalled, not on demand.
  @override
  Future<void> leave() async {}

  @override
  Stream<void> get onLost => const Stream<void>.empty();

  /// A NEHotspotConfiguration join is already system-owned and survives the
  /// screen going off, so there is no drop-and-recover cycle to report.
  @override
  Stream<void> get onRebound => const Stream<void>.empty();
}

/// Android join side: joins the host's hotspot from inside the app through
/// `WifiNetworkSpecifier` and pins the process to that network (see
/// WifiJoinHandler.kt).
///
/// The pinning is the important half. A local-only hotspot has no internet, so
/// once Android evaluates it, it moves the default network back to cellular and
/// the app's UDP quietly stops reaching the peer — the "connected, then dead
/// after a few seconds" report. A specifier network is app-scoped and never
/// evaluated, so that never happens.
///
/// Being app-scoped is also why the native side does not stop at the specifier:
/// that scope includes being in the foreground, so the link is dropped when the
/// screen locks and rebuilt from a network suggestion instead. [onRebound] is
/// how that round trip reaches Dart.
@injectable
class AndroidWifiJoiner implements HotspotJoiner {
  static const _channel = MethodChannel('tark/wifi_join');
  static const _events = EventChannel('tark/wifi_join/events');

  /// One underlying subscription for both event kinds. `receiveBroadcastStream`
  /// re-arms the native stream handler per listener, and the second listener
  /// replaces the first one's sink — so calling it twice left whichever stream
  /// was subscribed to first permanently silent.
  late final Stream<Map<Object?, Object?>> _stream = _events
      .receiveBroadcastStream()
      .where((e) => e is Map)
      .cast<Map<Object?, Object?>>()
      .asBroadcastStream();

  @override
  Stream<void> get onLost => _stream.where((event) {
    if (event['event'] != 'lost') return false;
    Logger.diagnostic(
      'network: selected wifi lost generation=${event['generation'] ?? 'unknown'}',
    );
    return true;
  }).map<void>((_) {});

  @override
  Stream<void> get onRebound => _stream.where((event) {
    if (event['event'] != 'rebound') return false;
    Logger.diagnostic(
      'network: selected wifi rebound generation=${event['generation'] ?? 'unknown'}',
    );
    return true;
  }).map<void>((_) {});

  @override
  Future<HotspotJoinResult> join(HotspotCredentials credentials) async {
    Logger.diagnostic('network: hotspot join requested');
    try {
      final ok = await _channel.invokeMethod<bool>('join', {
        'ssid': credentials.ssid,
        'passphrase': credentials.passphrase,
        'security': credentials.security,
      });
      if (ok != true) {
        Logger.diagnostic('network: hotspot join declined');
        Logger.log('Wi-Fi join declined by the framework (see TarkWifiJoin)');
      } else {
        Logger.diagnostic('network: hotspot join accepted');
      }
      return ok == true
          ? HotspotJoinResult.joined
          : HotspotJoinResult.declined;
    } on PlatformException catch (e) {
      // `wifi_off`, `foreground_required`, `no_ssid`, `failed`. Only the first
      // has a fix the user can act on from here; the rest land on the manual
      // card, and the log line is what tells them apart afterwards.
      Logger.diagnostic('network: hotspot join failed reason=${e.code}');
      Logger.log('Wi-Fi join failed: ${e.code} ${e.message}');
      return switch (e.code) {
        'wifi_off' => HotspotJoinResult.wifiOff,
        'location_off' => HotspotJoinResult.locationOff,
        _ => HotspotJoinResult.declined,
      };
    } on MissingPluginException {
      Logger.diagnostic('network: hotspot join failed reason=missing_plugin');
      Logger.log('Wi-Fi join unavailable: tark/wifi_join not registered');
      return HotspotJoinResult.declined;
    }
  }

  @override
  Future<bool> enableWifi() async {
    try {
      return await _channel.invokeMethod<bool>('enableWifi') ?? false;
    } on PlatformException catch (e) {
      Logger.log('Enable Wi-Fi failed: ${e.code} ${e.message}');
      return false;
    } on MissingPluginException {
      return false;
    }
  }

  @override
  Future<void> openLocationSettings() async {
    try {
      await _channel.invokeMethod<void>('openLocationSettings');
    } on PlatformException {
      // Some OEM builds have no such screen — nothing else to try.
    } on MissingPluginException {
      // Not Android.
    }
  }

  @override
  Future<bool> bindToCurrentWifi() async {
    Logger.diagnostic('network: bind current wifi requested');
    try {
      final bound = await _channel.invokeMethod<bool>('bindCurrent') ?? false;
      Logger.diagnostic(
        bound
            ? 'network: bind current wifi accepted'
            : 'network: bind current wifi unavailable',
      );
      return bound;
    } on PlatformException catch (e) {
      Logger.diagnostic('network: bind current wifi failed reason=${e.code}');
      return false;
    } on MissingPluginException {
      Logger.diagnostic('network: bind current wifi failed reason=missing_plugin');
      return false;
    }
  }

  @override
  Future<void> leave() async {
    Logger.diagnostic('network: selected wifi release requested');
    try {
      await _channel.invokeMethod<void>('leave');
      Logger.diagnostic('network: selected wifi released');
    } on PlatformException catch (e) {
      Logger.diagnostic('network: selected wifi release failed reason=${e.code}');
      // Best-effort — the request is also released when the activity dies.
    } on MissingPluginException {
      Logger.diagnostic('network: selected wifi release failed reason=missing_plugin');
      // Not Android.
    }
  }
}

/// Picks the join implementation for the running platform. The two sides use
/// entirely different OS APIs (NEHotspotConfiguration vs WifiNetworkSpecifier),
/// so they stay separate classes and this one only routes.
@LazySingleton(as: HotspotJoiner)
class PlatformHotspotJoiner implements HotspotJoiner {
  final NeHotspotJoiner _ios;
  final AndroidWifiJoiner _android;

  PlatformHotspotJoiner(this._ios, this._android);

  HotspotJoiner? get _delegate => switch (Platform.operatingSystem) {
    'ios' => _ios,
    'android' => _android,
    _ => null,
  };

  @override
  Future<HotspotJoinResult> join(HotspotCredentials credentials) async =>
      await _delegate?.join(credentials) ?? HotspotJoinResult.declined;

  @override
  Future<bool> enableWifi() async => await _delegate?.enableWifi() ?? false;

  @override
  Future<void> openLocationSettings() async => _delegate?.openLocationSettings();

  @override
  Future<bool> bindToCurrentWifi() async =>
      await _delegate?.bindToCurrentWifi() ?? false;

  @override
  Future<void> leave() async => _delegate?.leave();

  @override
  Stream<void> get onLost => _delegate?.onLost ?? const Stream<void>.empty();

  @override
  Stream<void> get onRebound =>
      _delegate?.onRebound ?? const Stream<void>.empty();
}
