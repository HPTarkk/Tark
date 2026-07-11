import 'dart:io';

import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart';

import '../../../../core/l10n/extension.dart';
import '../../../../core/theme/app_colors.dart';
import '../../../../core/utils/android_sdk.dart';
import '../../../../core/widget/permission_tile.dart';
import '../../../audio/api/audio_api.dart';

/// Overview of every permission/capability the app relies on, so a user
/// isn't surprised by scattered ad hoc prompts spread across the mic,
/// Bluetooth, and hotspot flows — one place to see status and grant/fix
/// each one. The Bluetooth-runtime trio and the hotspot host permissions
/// are Android-specific (iOS gates them differently, or not via
/// permission_handler at all), so those rows only render there.
class PermissionsPage extends StatefulWidget {
  const PermissionsPage._();

  static Widget buildPage() => const PermissionsPage._();

  @override
  State<PermissionsPage> createState() => _PermissionsPageState();
}

class _PermissionsPageState extends State<PermissionsPage>
    with WidgetsBindingObserver {
  PermissionTileStatus _mic = PermissionTileStatus.denied;
  PermissionTileStatus _bluetooth = PermissionTileStatus.denied;
  PermissionTileStatus _hotspot = PermissionTileStatus.denied;
  bool _batteryExempt = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _refresh();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _refresh();
  }

  PermissionTileStatus _tileStatus(PermissionStatus status) {
    if (status.isGranted) return PermissionTileStatus.granted;
    if (status.isPermanentlyDenied) {
      return PermissionTileStatus.permanentlyDenied;
    }
    return PermissionTileStatus.denied;
  }

  Future<void> _refresh() async {
    final mic = await Permission.microphone.status;
    var bluetooth = PermissionTileStatus.granted;
    var hotspot = PermissionTileStatus.granted;
    if (Platform.isAndroid) {
      final btStatuses = await Future.wait([
        Permission.bluetoothScan.status,
        Permission.bluetoothConnect.status,
        Permission.bluetoothAdvertise.status,
      ]);
      bluetooth = btStatuses.every((s) => s.isGranted)
          ? PermissionTileStatus.granted
          : btStatuses.any((s) => s.isPermanentlyDenied)
          ? PermissionTileStatus.permanentlyDenied
          : PermissionTileStatus.denied;

      hotspot = _tileStatus(await (await _hotspotPermission()).status);
    }
    final batteryExempt = Platform.isAndroid
        ? await SessionKeepAlive.isIgnoringBatteryOptimizations()
        : true;
    if (!mounted) return;
    setState(() {
      _mic = _tileStatus(mic);
      _bluetooth = bluetooth;
      _hotspot = hotspot;
      _batteryExempt = batteryExempt;
    });
  }

  Future<void> _requestMic() async {
    await Permission.microphone.request();
    await _refresh();
  }

  Future<void> _requestBluetooth() async {
    await [
      Permission.bluetoothScan,
      Permission.bluetoothConnect,
      Permission.bluetoothAdvertise,
    ].request();
    await _refresh();
  }

  /// LocalOnlyHotspot is gated by NEARBY_WIFI_DEVICES on Android 13+ but
  /// fine location on 26–32, and the manifest declares each only for its
  /// own SDK range. permission_handler resolves a permission absent from
  /// the (SDK-filtered) manifest as denied without ever prompting, so
  /// touching the wrong-generation permission reads denied forever and
  /// turns the grant tap into a silent no-op — pick by API level instead.
  Future<Permission> _hotspotPermission() async {
    var sdk = 33;
    try {
      sdk = await AndroidSdk.version();
    } catch (_) {
      // Assume modern Android when the lookup fails.
    }
    return sdk >= 33
        ? Permission.nearbyWifiDevices
        : Permission.locationWhenInUse;
  }

  Future<void> _requestHotspot() async {
    await (await _hotspotPermission()).request();
    await _refresh();
  }

  @override
  Widget build(BuildContext context) {
    final s = context.getString;
    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        backgroundColor: AppColors.background,
        title: Text(
          s.permissions_title,
          style: TextStyle(color: AppColors.textPrimary),
        ),
        iconTheme: IconThemeData(color: AppColors.textPrimary),
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          PermissionTile(
            icon: Icons.mic_rounded,
            title: s.permission_mic_title,
            description: s.permission_mic_desc,
            status: _mic,
            onRequest: _requestMic,
            onOpenSettings: openAppSettings,
          ),
          if (Platform.isAndroid) ...[
            PermissionTile(
              icon: Icons.bluetooth_rounded,
              title: s.permission_bluetooth_title,
              description: s.permission_bluetooth_desc,
              status: _bluetooth,
              onRequest: _requestBluetooth,
              onOpenSettings: openAppSettings,
            ),
            PermissionTile(
              icon: Icons.wifi_tethering_rounded,
              title: s.permission_hotspot_title,
              description: s.permission_hotspot_desc,
              status: _hotspot,
              onRequest: _requestHotspot,
              onOpenSettings: openAppSettings,
            ),
            PermissionTile(
              icon: Icons.battery_saver_rounded,
              title: s.permission_battery_title,
              description: s.permission_battery_desc,
              status: _batteryExempt
                  ? PermissionTileStatus.granted
                  : PermissionTileStatus.denied,
              onRequest: () =>
                  SessionKeepAlive.requestIgnoreBatteryOptimizations(),
              onOpenSettings: () =>
                  SessionKeepAlive.requestIgnoreBatteryOptimizations(),
            ),
          ],
        ],
      ),
    );
  }
}
