import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:get_it/get_it.dart';
import 'package:go_router/go_router.dart';
import 'package:permission_handler/permission_handler.dart';

import '../../../../core/l10n/app_localizations.dart';
import '../../../../core/l10n/extension.dart';
import '../../../../core/router/routes.dart';
import '../../../../core/widget/link_established.dart';
import '../../../../core/theme/app_colors.dart';
import '../../../../core/utils/android_sdk.dart';
import '../../../../core/utils/logger.dart';
import '../../../../core/utils/permission_queue.dart';
import '../../../../core/analytics/analytics_event.dart';
import '../../domain/entity/bluetooth_connection_state.dart';
import '../../domain/entity/bluetooth_role.dart';
import '../../domain/entity/channel_intent.dart';
import '../manager/bluetooth_connect_cubit.dart';
import '../widget/bluetooth_host_beacon.dart';
import '../widget/bluetooth_joiner_radar.dart';
import '../widget/bluetooth_role_selection.dart';
import '../widget/bluetooth_status_views.dart';

class BluetoothConnectPage extends StatefulWidget {
  const BluetoothConnectPage._({this.intent});

  /// The side the user already chose on the landing page, or null when the
  /// page was reached without one (quick access, the home-screen widget) and
  /// should ask for itself.
  final ChannelIntent? intent;

  static Widget buildPage({ChannelIntent? intent}) =>
      BlocProvider<BluetoothConnectCubit>(
        create: (_) => GetIt.instance<BluetoothConnectCubit>(),
        child: BluetoothConnectPage._(intent: intent),
      );

  @override
  State<BluetoothConnectPage> createState() => _BluetoothConnectPageState();
}

class _BluetoothConnectPageState extends State<BluetoothConnectPage> {
  bool _permissionDenied = false;
  bool _navigatingToWalkie = false;

  @override
  void initState() {
    super.initState();
    if (widget.intent != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _applyIntent());
    }
  }

  /// Takes the side the landing page already asked about.
  ///
  /// Runs the same permission gate the role cards run rather than starting
  /// straight away — the Bluetooth APIs do nothing at all without it on
  /// Android, and skipping it here would turn a preselected side into a screen
  /// that silently never finds anybody. A denial leaves [role] unset, so the
  /// page falls back to its own role selection with the permission notice
  /// showing: the intent is a shortcut past a question, never past a
  /// requirement.
  ///
  /// Deferred to after the first frame because it awaits, and the permission
  /// prompt has to have something to sit in front of.
  Future<void> _applyIntent() async {
    final host = widget.intent == ChannelIntent.create;
    final cubit = context.read<BluetoothConnectCubit>();
    if (!await _ensurePermissions()) {
      cubit.reportPermissionBlocked(host ? PairRole.host : PairRole.joiner);
      return;
    }
    if (!mounted) return;
    if (host) {
      cubit.startHosting();
    } else {
      cubit.startScanning();
    }
  }

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
    final requested = <Permission>[
      Permission.bluetoothScan,
      Permission.bluetoothConnect,
      Permission.bluetoothAdvertise,
    ];
    // Pre-S Android has no granular Bluetooth permissions at all — scanning
    // and BLE advertising are gated on location instead, so the three above
    // resolve to "granted" without ever prompting, and the BLE stack raises
    // the location prompt ITSELF the moment hosting starts. That prompt is a
    // requestPermissions() call we don't own and can't serialize, so it
    // collided with the microphone request the walkie session fires when a
    // peer connects — Android drops whichever lands second
    // ("W/Activity: Can request only one set of permissions at a time") and
    // permission_handler never completes the dropped one's Future. Asking for
    // location up front, through the queue, means the BLE stack finds it
    // already granted and never prompts. See [PermissionQueue].
    if (await _isPreAndroidS()) {
      requested.add(Permission.locationWhenInUse);
    }
    if (!mounted) return false;
    final statuses = await PermissionQueue.run(() => requested.request());
    final granted = statuses.values.every((s) => s.isGranted);
    if (mounted) setState(() => _permissionDenied = !granted);
    return granted;
  }

  /// Assumes modern Android when the lookup fails, matching PermissionsPage:
  /// pre-S is the special case, so defaulting to S+ keeps the long-standing
  /// behaviour rather than asking every modern device for a location
  /// permission it does not need.
  Future<bool> _isPreAndroidS() async {
    try {
      return await AndroidSdk.version() < 31;
    } catch (e) {
      Logger.log('SDK lookup failed, assuming Android S+: $e');
      return false;
    }
  }

  /// Back steps out of a chosen side first (host ⇄ join is a decision worth
  /// being able to undo), and only leaves the page once there's no side to
  /// step out of.
  void _back(BuildContext context) {
    final cubit = context.read<BluetoothConnectCubit>();
    if (cubit.state.role != null) {
      cubit.backToRoleSelection();
      return;
    }
    if (context.canPop()) {
      context.pop();
    } else {
      // Reached directly, with nothing beneath us on the stack — quick
      // access lands here on cold start, and so does the home-screen
      // widget's GO LIVE in Bluetooth mode.
      context.goNamed(AppRoutes.landingName);
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = context.getString;
    return PopScope(
      // Without this the system back gesture pops the route directly. When
      // this page IS the route (quick access / the widget started here) that
      // empties the stack and closes the app instead of going to Landing —
      // and even with a stack it would skip the role step-out above, so the
      // two back affordances would disagree.
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _back(context);
      },
      child: _buildScaffold(context, s),
    );
  }

  Widget _buildScaffold(BuildContext context, AppLocalizations s) {
    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        backgroundColor: AppColors.background,
        elevation: 0,
        leading: IconButton(
          icon: Icon(Icons.arrow_back_rounded, color: AppColors.textPrimary),
          onPressed: () => _back(context),
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
                await Future<void>.delayed(LinkEstablished.hold);
                if (!context.mounted) return;
                try {
                  context.goNamed(AppRoutes.walkieName);
                } catch (e) {
                  // The flash keeps rendering for as long as the flag is set,
                  // so a jump that never lands leaves the user parked on
                  // "you're in!" with only the back arrow — the link is up and
                  // the channel is unreachable. Drop the flag so the next
                  // connected emission gets another go instead of latching.
                  Logger.log('Walkie navigation failed: $e');
                  if (mounted) setState(() => _navigatingToWalkie = false);
                }
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
