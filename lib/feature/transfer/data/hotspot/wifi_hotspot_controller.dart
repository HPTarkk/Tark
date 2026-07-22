import 'dart:io';

import 'package:flutter/services.dart';
import 'package:injectable/injectable.dart';

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

  /// Fires when the OS tears the hotspot down on its own — a radio conflict, an
  /// STA reconnect stealing the single radio, Doze, etc. — as opposed to our
  /// own [stop]. Lets a host recover instead of silently going dead. Never
  /// emits for an app-initiated teardown (see HotspotHandler.expectingStop).
  @override
  Stream<void> get onStopped => _events
      .receiveBroadcastStream()
      .where((e) => e is Map && e['event'] == 'stopped')
      .map<void>((_) {});

  /// Starts a local-only Wi-Fi hotspot and returns its credentials. Throws a
  /// [PlatformException] (code `tethering_on`, `location_off`,
  /// `permission_denied`, `no_channel`, `failed`, …) or [UnsupportedError] off
  /// Android; callers surface that as an error card.
  @override
  Future<HotspotCredentials> start() async {
    if (!isSupported) {
      throw UnsupportedError('Hotspot hosting requires Android.');
    }
    final result =
        await _channel.invokeMapMethod<String, dynamic>('start') ?? const {};
    final ssid = (result['ssid'] as String?) ?? '';
    final passphrase = (result['passphrase'] as String?) ?? '';
    final security = (result['security'] as String?) ?? 'WPA';
    if (ssid.isEmpty) {
      throw PlatformException(
        code: 'no_credentials',
        message: 'Hotspot started without an SSID',
      );
    }
    return HotspotCredentials(
      ssid: ssid,
      passphrase: passphrase,
      security: security,
    );
  }

  @override
  Future<void> stop() async {
    if (!isSupported) return;
    try {
      await _channel.invokeMethod<void>('stop');
    } on PlatformException {
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
  Future<bool> join(HotspotCredentials credentials) async {
    try {
      final ok = await _channel.invokeMethod<bool>('join', {
        'ssid': credentials.ssid,
        'passphrase': credentials.passphrase,
      });
      return ok ?? false;
    } on PlatformException {
      return false;
    } on MissingPluginException {
      return false;
    }
  }

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
@injectable
class AndroidWifiJoiner implements HotspotJoiner {
  static const _channel = MethodChannel('tark/wifi_join');
  static const _events = EventChannel('tark/wifi_join/events');

  @override
  Stream<void> get onLost => _events
      .receiveBroadcastStream()
      .where((e) => e is Map && e['event'] == 'lost')
      .map<void>((_) {});

  @override
  Future<bool> join(HotspotCredentials credentials) async {
    try {
      final ok = await _channel.invokeMethod<bool>('join', {
        'ssid': credentials.ssid,
        'passphrase': credentials.passphrase,
        'security': credentials.security,
      });
      return ok ?? false;
    } on PlatformException {
      return false;
    } on MissingPluginException {
      return false;
    }
  }

  @override
  Future<bool> bindToCurrentWifi() async {
    try {
      return await _channel.invokeMethod<bool>('bindCurrent') ?? false;
    } on PlatformException {
      return false;
    } on MissingPluginException {
      return false;
    }
  }

  @override
  Future<void> leave() async {
    try {
      await _channel.invokeMethod<void>('leave');
    } on PlatformException {
      // Best-effort — the request is also released when the activity dies.
    } on MissingPluginException {
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
  Future<bool> join(HotspotCredentials credentials) async =>
      await _delegate?.join(credentials) ?? false;

  @override
  Future<bool> bindToCurrentWifi() async =>
      await _delegate?.bindToCurrentWifi() ?? false;

  @override
  Future<void> leave() async => _delegate?.leave();

  @override
  Stream<void> get onLost => _delegate?.onLost ?? const Stream<void>.empty();
}
