import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart';

import '../theme/app_colors.dart';

/// What a runtime permission is *for*, as the person sees it.
///
/// One kind can stand for several platform permissions — Bluetooth on
/// Android 12+ is three of them (scan, connect, advertise) — and one platform
/// permission can wear two kinds: older Android puts both Bluetooth scanning
/// and the hotspot behind location. The primer always speaks about the kind,
/// never the permission strings Android happens to use for it.
enum PermissionKind {
  /// Picking up the rider's voice.
  microphone,

  /// Reading an invite or connection QR code.
  camera,

  /// Finding and linking to phones over Bluetooth (Android 12+).
  nearbyDevices,

  /// Raising a local hotspot and seeing who joins it (Android 13+).
  nearbyWifi,

  /// Location, which older Android demands before it will scan for phones or
  /// raise a hotspot. Never used for where the rider is.
  location,

  /// The keep-alive notification that stops Android closing the channel.
  notifications;

  /// The kind a set of platform permissions belongs to.
  static PermissionKind of(Iterable<Permission> permissions) {
    final list = permissions.toList();
    if (list.any(_isBluetooth)) return nearbyDevices;
    if (list.contains(Permission.nearbyWifiDevices)) return nearbyWifi;
    if (list.any(isLocation)) return location;
    if (list.contains(Permission.camera)) return camera;
    if (list.contains(Permission.notification)) return notifications;
    return microphone;
  }

  /// The kind to *show* for a request made as [requested] when only
  /// [missing] still needs an answer.
  ///
  /// Pre-S Android reports the Bluetooth trio granted without asking and
  /// gates scanning on location instead; pre-T does the same to the hotspot.
  /// Asking those phones for "nearby devices" would explain a permission the
  /// dialog that follows never mentions, so the visual follows the dialog.
  static PermissionKind visualFor(
    PermissionKind requested,
    Iterable<Permission> missing,
  ) {
    final list = missing.toList();
    if (list.isNotEmpty && list.every(isLocation)) return location;
    return requested;
  }

  static bool isLocation(Permission p) =>
      p == Permission.location ||
      p == Permission.locationWhenInUse ||
      p == Permission.locationAlways;

  static bool _isBluetooth(Permission p) =>
      p == Permission.bluetooth ||
      p == Permission.bluetoothScan ||
      p == Permission.bluetoothConnect ||
      p == Permission.bluetoothAdvertise;

  /// This kind's own colour: one identity per permission, all of them drawn
  /// from the website's forest greens ([ForestPalette]) so the primer reads
  /// as one system. The microphone takes the site's own highlight green —
  /// talking is the product.
  Color get accent => accentOn(AppColors.palette);

  /// [accent] for a specific palette rather than the active theme.
  Color accentOn(AppPalette palette) {
    final forest = ForestPalette.of(palette);
    return switch (this) {
      microphone => forest.leaf,
      camera => forest.mint,
      nearbyDevices => forest.lagoon,
      nearbyWifi => forest.jade,
      location => forest.lime,
      notifications => forest.sage,
    };
  }

  IconData get icon => switch (this) {
    microphone => Icons.mic_rounded,
    camera => Icons.qr_code_scanner_rounded,
    nearbyDevices => Icons.bluetooth_rounded,
    nearbyWifi => Icons.wifi_tethering_rounded,
    location => Icons.place_rounded,
    notifications => Icons.notifications_active_rounded,
  };
}
