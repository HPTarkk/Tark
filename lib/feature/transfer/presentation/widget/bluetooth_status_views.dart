import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart';

import '../../../../core/l10n/extension.dart';
import '../../../../core/motion/scene_turn.dart';
import '../../../../core/theme/app_colors.dart';
import '../../../../core/widget/connection_journey.dart';
import '../../../../core/widget/permission_tile.dart';
import '../../../../core/widget/state_emblems.dart';
import 'network_link_established.dart';

/// Full-screen status views the Bluetooth connect page switches between:
/// connected flash, connection error, permission recovery, and a status
/// message drawn round a living emblem.

/// The tether locking in: the Bluetooth beat of the app's one
/// [ConnectionJourney] scene, held for [NetworkLinkEstablished.hold] before
/// the page opens the channel out of it.
class BluetoothConnectedFlash extends StatelessWidget {
  const BluetoothConnectedFlash({super.key});

  @override
  Widget build(BuildContext context) =>
      const NetworkLinkEstablished(hotspot: false, bluetooth: true);
}

/// The tether not happening, told in the same scene it would have locked
/// in: the wave decoheres into static between the two phones, with the way
/// forward under it.
class BluetoothErrorCard extends StatelessWidget {
  final VoidCallback onRetry;

  const BluetoothErrorCard({super.key, required this.onRetry});

  @override
  Widget build(BuildContext context) {
    final s = context.getString;
    final shape = RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(16),
    );
    return ConnectionJourney(
      stage: JourneyStage.failed,
      link: JourneyLink.bluetooth,
      title: s.rcv_bt_failed_title,
      detail: s.rcv_bt_failed_detail,
      actions: [
        FilledButton.icon(
          key: const Key('bluetooth-error-retry'),
          onPressed: onRetry,
          style: FilledButton.styleFrom(
            padding: const EdgeInsets.symmetric(vertical: 15),
            shape: shape,
          ),
          icon: const Icon(Icons.refresh_rounded),
          label: Text(
            s.retry,
            style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w800),
          ),
        ),
        // On iOS a denied Bluetooth prompt lands here, and by now the
        // Settings row exists, so this is the recovery path.
        TextButton(
          key: const Key('bluetooth-error-settings'),
          onPressed: openAppSettings,
          child: Text(
            s.open_settings,
            style: TextStyle(
              color: AppColors.textSecondary,
              fontSize: 13,
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
      ],
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
            // The radio searching for the go-ahead it needs, not a still
            // "disabled" glyph.
            const SceneReflow(
              index: 0,
              child: ScanSweepEmblem(
                icon: Icons.bluetooth_searching_rounded,
                size: 96,
              ),
            ),
            const SizedBox(height: 18),
            SceneReflow(
              index: 1,
              child: Text(
                s.bt_permission_denied,
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: AppColors.textPrimary,
                  fontSize: 15,
                  height: 1.45,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
            const SizedBox(height: 22),
            SceneReflow(
              index: 2,
              child: PermissionTile(
                icon: Icons.search_rounded,
                title: s.permission_bt_scan_title,
                description: s.permission_bt_scan_desc,
                status: _scan,
                onRequest: _requestAll,
                onOpenSettings: widget.onOpenSettings,
              ),
            ),
            SceneReflow(
              index: 3,
              child: PermissionTile(
                icon: Icons.bluetooth_connected_rounded,
                title: s.permission_bt_connect_title,
                description: s.permission_bt_connect_desc,
                status: _connect,
                onRequest: _requestAll,
                onOpenSettings: widget.onOpenSettings,
              ),
            ),
            SceneReflow(
              index: 4,
              child: PermissionTile(
                icon: Icons.campaign_rounded,
                title: s.permission_bt_advertise_title,
                description: s.permission_bt_advertise_desc,
                status: _advertise,
                onRequest: _requestAll,
                onOpenSettings: widget.onOpenSettings,
              ),
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
            SceneReflow(index: 0, child: ScanSweepEmblem(icon: icon, size: 96)),
            const SizedBox(height: 20),
            SceneReflow(
              index: 1,
              child: Text(
                text,
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: AppColors.textPrimary,
                  fontSize: 15,
                  height: 1.45,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
