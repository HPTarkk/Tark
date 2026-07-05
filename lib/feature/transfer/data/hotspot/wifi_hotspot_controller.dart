import 'dart:io';

import 'package:flutter/services.dart';

import '../../domain/entity/hotspot_credentials.dart';

/// Android host side of the hotspot bridge: drives `WifiManager
/// .startLocalOnlyHotspot` over the native `tark/hotspot` channel
/// (see HotspotHandler.kt).
///
/// The reservation is held open natively across navigation to the walkie
/// screen — [stop] is what tears it down (when the user leaves the session).
class WifiHotspotController {
  static const _channel = MethodChannel('tark/hotspot');

  bool get isSupported => Platform.isAndroid;

  /// Starts a local-only Wi-Fi hotspot and returns its credentials. Throws a
  /// [PlatformException] (code `tethering_on`, `unsupported`, `failed`, …) or
  /// [UnsupportedError] off Android; callers surface that as an error card.
  Future<HotspotCredentials> start() async {
    if (!isSupported) {
      throw UnsupportedError('Hotspot hosting requires Android.');
    }
    final result =
        await _channel.invokeMapMethod<String, dynamic>('start') ?? const {};
    final ssid = (result['ssid'] as String?) ?? '';
    final passphrase = (result['passphrase'] as String?) ?? '';
    if (ssid.isEmpty) {
      throw PlatformException(
        code: 'no_credentials',
        message: 'Hotspot started without an SSID',
      );
    }
    return HotspotCredentials(ssid: ssid, passphrase: passphrase);
  }

  Future<void> stop() async {
    if (!isSupported) return;
    try {
      await _channel.invokeMethod<void>('stop');
    } on PlatformException {
      // Best-effort teardown — the reservation also closes with the activity.
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
class HotspotJoiner {
  static const _channel = MethodChannel('tark/hotspot_join');

  bool get isSupported => Platform.isIOS;

  Future<bool> join({
    required String ssid,
    required String passphrase,
  }) async {
    if (!isSupported) return false;
    try {
      final ok = await _channel.invokeMethod<bool>('join', {
        'ssid': ssid,
        'passphrase': passphrase,
      });
      return ok ?? false;
    } on PlatformException {
      return false;
    } on MissingPluginException {
      return false;
    }
  }
}
