import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart';

import '../../../../core/l10n/extension.dart';
import '../../../../core/theme/app_colors.dart';
import '../../../../core/widget/permission_tile.dart';

/// Full-screen status views the Bluetooth connect page switches between:
/// connected flash, connection error, permission recovery, and the generic
/// icon+text message.

class BluetoothConnectedFlash extends StatelessWidget {
  const BluetoothConnectedFlash({super.key});

  @override
  Widget build(BuildContext context) {
    final s = context.getString;
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          TweenAnimationBuilder<double>(
            tween: Tween(begin: 0.4, end: 1.0),
            duration: const Duration(milliseconds: 450),
            curve: Curves.elasticOut,
            builder: (context, scale, child) =>
                Transform.scale(scale: scale, child: child),
            child: Container(
              width: 84,
              height: 84,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: AppColors.green.withAlpha(26),
                border: Border.all(color: AppColors.green, width: 2),
                boxShadow: [
                  BoxShadow(
                    color: AppColors.green.withAlpha(70),
                    blurRadius: 26,
                  ),
                ],
              ),
              child: Icon(
                Icons.check_rounded,
                color: AppColors.green,
                size: 42,
              ),
            ),
          ),
          const SizedBox(height: 18),
          Text(
            s.bt_connected,
            style: TextStyle(
              color: AppColors.textPrimary,
              fontSize: 15,
              fontWeight: FontWeight.w700,
              letterSpacing: 1,
            ),
          ),
        ],
      ),
    );
  }
}

class BluetoothErrorCard extends StatelessWidget {
  final VoidCallback onRetry;

  const BluetoothErrorCard({super.key, required this.onRetry});

  @override
  Widget build(BuildContext context) {
    final s = context.getString;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.error_outline_rounded, color: AppColors.red, size: 40),
            const SizedBox(height: 16),
            Text(
              s.bt_connection_failed,
              textAlign: TextAlign.center,
              style: TextStyle(color: AppColors.textSecondary, fontSize: 14),
            ),
            const SizedBox(height: 22),
            GestureDetector(
              onTap: onRetry,
              child: Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 26,
                  vertical: 12,
                ),
                decoration: BoxDecoration(
                  color: AppColors.amber.withAlpha(25),
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(
                    color: AppColors.amber.withAlpha(120),
                    width: 1.5,
                  ),
                ),
                child: Text(
                  s.retry,
                  style: TextStyle(
                    color: AppColors.amber,
                    fontSize: 12,
                    fontWeight: FontWeight.w800,
                    letterSpacing: 1.5,
                  ),
                ),
              ),
            ),
            const SizedBox(height: 8),
            // On iOS a denied Bluetooth prompt lands on this card — and by
            // now the Settings row exists, so this is the recovery path.
            TextButton(
              onPressed: openAppSettings,
              child: Text(
                s.open_settings,
                style: TextStyle(
                  color: AppColors.textSecondary,
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  letterSpacing: 1,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class BluetoothPermissionDenied extends StatefulWidget {
  final Future<void> Function() onOpenSettings;
  final Future<bool> Function() onRetry;

  const BluetoothPermissionDenied({
    super.key,
    required this.onOpenSettings,
    required this.onRetry,
  });

  @override
  State<BluetoothPermissionDenied> createState() =>
      _BluetoothPermissionDeniedState();
}

class _BluetoothPermissionDeniedState extends State<BluetoothPermissionDenied> {
  PermissionTileStatus _scan = PermissionTileStatus.denied;
  PermissionTileStatus _connect = PermissionTileStatus.denied;
  PermissionTileStatus _advertise = PermissionTileStatus.denied;

  @override
  void initState() {
    super.initState();
    _refreshStatuses();
  }

  PermissionTileStatus _tileStatus(PermissionStatus status) {
    if (status.isGranted) return PermissionTileStatus.granted;
    if (status.isPermanentlyDenied) {
      return PermissionTileStatus.permanentlyDenied;
    }
    return PermissionTileStatus.denied;
  }

  Future<void> _refreshStatuses() async {
    final statuses = await Future.wait([
      Permission.bluetoothScan.status,
      Permission.bluetoothConnect.status,
      Permission.bluetoothAdvertise.status,
    ]);
    if (!mounted) return;
    setState(() {
      _scan = _tileStatus(statuses[0]);
      _connect = _tileStatus(statuses[1]);
      _advertise = _tileStatus(statuses[2]);
    });
  }

  // All three are requested together (Android grants them as one dialog),
  // so every tile's "grant" action re-runs the same batch request.
  Future<void> _requestAll() async {
    await widget.onRetry();
    await _refreshStatuses();
  }

  @override
  Widget build(BuildContext context) {
    final s = context.getString;
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.bluetooth_disabled_rounded,
              color: AppColors.amber,
              size: 40,
            ),
            const SizedBox(height: 12),
            Text(
              s.bt_permission_denied,
              textAlign: TextAlign.center,
              style: TextStyle(color: AppColors.textSecondary, fontSize: 14),
            ),
            const SizedBox(height: 20),
            PermissionTile(
              icon: Icons.search_rounded,
              title: s.permission_bt_scan_title,
              description: s.permission_bt_scan_desc,
              status: _scan,
              onRequest: _requestAll,
              onOpenSettings: widget.onOpenSettings,
            ),
            PermissionTile(
              icon: Icons.bluetooth_connected_rounded,
              title: s.permission_bt_connect_title,
              description: s.permission_bt_connect_desc,
              status: _connect,
              onRequest: _requestAll,
              onOpenSettings: widget.onOpenSettings,
            ),
            PermissionTile(
              icon: Icons.campaign_rounded,
              title: s.permission_bt_advertise_title,
              description: s.permission_bt_advertise_desc,
              status: _advertise,
              onRequest: _requestAll,
              onOpenSettings: widget.onOpenSettings,
            ),
          ],
        ),
      ),
    );
  }
}

class BluetoothStatusMessage extends StatelessWidget {
  final IconData icon;
  final String text;

  const BluetoothStatusMessage({
    super.key,
    required this.icon,
    required this.text,
  });

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, color: AppColors.amber, size: 40),
            const SizedBox(height: 16),
            Text(
              text,
              textAlign: TextAlign.center,
              style: TextStyle(color: AppColors.textSecondary, fontSize: 14),
            ),
          ],
        ),
      ),
    );
  }
}
