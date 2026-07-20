import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:get_it/get_it.dart';
import 'package:go_router/go_router.dart';
import 'package:permission_handler/permission_handler.dart';

import '../../../../core/l10n/extension.dart';
import '../../../../core/router/routes.dart';
import '../../../../core/theme/app_colors.dart';
import '../../domain/entity/bluetooth_connection_state.dart';
import '../../domain/entity/bluetooth_role.dart';
import '../manager/bluetooth_connect_cubit.dart';
import '../widget/bluetooth_host_beacon.dart';
import '../widget/bluetooth_joiner_radar.dart';
import '../widget/bluetooth_role_selection.dart';
import '../widget/bluetooth_status_views.dart';

class BluetoothConnectPage extends StatefulWidget {
  const BluetoothConnectPage._();

  static Widget buildPage() => BlocProvider<BluetoothConnectCubit>(
    create: (_) => GetIt.instance<BluetoothConnectCubit>(),
    child: const BluetoothConnectPage._(),
  );

  @override
  State<BluetoothConnectPage> createState() => _BluetoothConnectPageState();
}

class _BluetoothConnectPageState extends State<BluetoothConnectPage> {
  bool _permissionDenied = false;
  bool _navigatingToWalkie = false;

  Future<bool> _ensurePermissions() async {
    // iOS: the system Bluetooth prompt only appears when CoreBluetooth is
    // actually used — permission_handler reports "denied" before that, and
    // the app's Settings page doesn't even have a Bluetooth row yet.
    // Gating here made a dead-end. Proceed and let the BLE engine's manager
    // trigger the real prompt; a denial then surfaces as a connection error
    // (with the Settings row finally existing).
    if (Platform.isIOS) {
      if (mounted) setState(() => _permissionDenied = false);
      return true;
    }
    // Android needs the granular BT runtime permissions (advertise included,
    // for BLE hosting) BEFORE any Bluetooth API works.
    final statuses = await [
      Permission.bluetoothScan,
      Permission.bluetoothConnect,
      Permission.bluetoothAdvertise,
    ].request();
    final granted = statuses.values.every((s) => s.isGranted);
    if (mounted) setState(() => _permissionDenied = !granted);
    return granted;
  }

  @override
  Widget build(BuildContext context) {
    final s = context.getString;
    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        backgroundColor: AppColors.background,
        elevation: 0,
        leading: IconButton(
          icon: Icon(Icons.arrow_back_rounded, color: AppColors.textPrimary),
          onPressed: () {
            final cubit = context.read<BluetoothConnectCubit>();
            if (cubit.state.role != null) {
              cubit.backToRoleSelection();
            } else if (context.canPop()) {
              context.pop();
            } else {
              // Reached directly (quick access landed here) — no stack to
              // pop to.
              context.goNamed(AppRoutes.landingName);
            }
          },
        ),
        title: Text(
          s.transport_bluetooth,
          style: TextStyle(color: AppColors.textPrimary, fontSize: 16),
        ),
      ),
      body: SafeArea(
        child: Align(
          alignment: Alignment.topCenter,
          child: BlocConsumer<BluetoothConnectCubit, BluetoothConnectState>(
            listener: (context, state) async {
              if (state.connectionState == BluetoothConnectionState.connected &&
                  !_navigatingToWalkie) {
                // Let the success check land before jumping to the channel.
                setState(() => _navigatingToWalkie = true);
                await Future<void>.delayed(const Duration(milliseconds: 900));
                if (context.mounted) context.goNamed(AppRoutes.walkieName);
              }
            },
            builder: (context, state) {
              // Android runs Classic RFCOMM + BLE; iOS runs BLE. Anything
              // else (desktop, web) has no Bluetooth transport.
              if (!Platform.isAndroid && !Platform.isIOS) {
                return BluetoothStatusMessage(
                  icon: Icons.bluetooth_disabled_rounded,
                  text: s.bt_not_supported_platform,
                );
              }
              if (_permissionDenied) {
                return BluetoothPermissionDenied(
                  onOpenSettings: openAppSettings,
                  onRetry: _ensurePermissions,
                );
              }
              if (state.connectionState == BluetoothConnectionState.connected ||
                  _navigatingToWalkie) {
                return const BluetoothConnectedFlash();
              }
              if (state.connectionState == BluetoothConnectionState.error) {
                return BluetoothErrorCard(
                  onRetry: () => context
                      .read<BluetoothConnectCubit>()
                      .backToRoleSelection(),
                );
              }
              if (state.role == null) {
                return BluetoothRoleSelection(
                  onEnsurePermissions: _ensurePermissions,
                );
              }
              if (state.role == BluetoothRole.host) {
                return BluetoothHostBeacon(state: state);
              }
              return BluetoothJoinerRadar(state: state);
            },
          ),
        ),
      ),
    );
  }
}
