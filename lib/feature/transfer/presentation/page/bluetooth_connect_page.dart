import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:get_it/get_it.dart';
import 'package:go_router/go_router.dart';
import 'package:permission_handler/permission_handler.dart';

import '../../../../core/l10n/extension.dart';
import '../../../../core/theme/app_colors.dart';
import '../../../walkie/presentation/page/walkie_talkie_page.dart';
import '../../domain/entity/bluetooth_connection_state.dart';
import '../../domain/entity/bluetooth_peer.dart';
import '../../domain/entity/bluetooth_role.dart';
import '../manager/bluetooth_connect_cubit.dart';

class BluetoothConnectPage extends StatefulWidget {
  static const path = 'bluetooth-connect';
  static const name = 'BluetoothConnectPage';

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

  Future<bool> _ensurePermissions() async {
    final statuses = await [
      Permission.bluetoothScan,
      Permission.bluetoothConnect,
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
            } else {
              context.pop();
            }
          },
        ),
        title: Text(
          s.transport_bluetooth,
          style: TextStyle(color: AppColors.textPrimary, fontSize: 16),
        ),
      ),
      body: SafeArea(
        child: BlocConsumer<BluetoothConnectCubit, BluetoothConnectState>(
          listener: (context, state) {
            if (state.connectionState == BluetoothConnectionState.connected) {
              context.goNamed(WalkieTalkiePage.name);
            }
          },
          builder: (context, state) {
            if (_permissionDenied) {
              return _Message(
                icon: Icons.bluetooth_disabled_rounded,
                text: s.bt_permission_denied,
              );
            }
            if (state.connectionState == BluetoothConnectionState.error) {
              return _Message(
                icon: Icons.error_outline_rounded,
                text: s.bt_connection_failed,
              );
            }
            if (state.role == null) {
              return _RoleSelection(onEnsurePermissions: _ensurePermissions);
            }
            if (state.role == BluetoothRole.host) {
              return _HostWaiting(state: state);
            }
            return _JoinerScan(state: state);
          },
        ),
      ),
    );
  }
}

// ── Role selection ──────────────────────────────────────────────────────────

class _RoleSelection extends StatelessWidget {
  final Future<bool> Function() onEnsurePermissions;

  const _RoleSelection({required this.onEnsurePermissions});

  @override
  Widget build(BuildContext context) {
    final s = context.getString;
    return Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          _RoleButton(
            icon: Icons.podcasts_rounded,
            label: s.bt_start_session,
            onTap: () async {
              if (!await onEnsurePermissions()) return;
              if (!context.mounted) return;
              context.read<BluetoothConnectCubit>().startHosting();
            },
          ),
          const SizedBox(height: 16),
          _RoleButton(
            icon: Icons.search_rounded,
            label: s.bt_find_nearby,
            onTap: () async {
              if (!await onEnsurePermissions()) return;
              if (!context.mounted) return;
              context.read<BluetoothConnectCubit>().startScanning();
            },
          ),
        ],
      ),
    );
  }
}

class _RoleButton extends StatelessWidget {
  final IconData icon;
  final String label;
  final VoidCallback onTap;

  const _RoleButton({required this.icon, required this.label, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.symmetric(vertical: 20),
        decoration: BoxDecoration(
          color: AppColors.amber.withAlpha(25),
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: AppColors.amber.withAlpha(120), width: 2),
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(icon, color: AppColors.amber, size: 22),
            const SizedBox(width: 12),
            Text(
              label,
              style: TextStyle(
                color: AppColors.amber,
                fontSize: 15,
                fontWeight: FontWeight.w800,
                letterSpacing: 1.5,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ── Host: waiting for a peer ────────────────────────────────────────────────

class _HostWaiting extends StatelessWidget {
  final BluetoothConnectState state;

  const _HostWaiting({required this.state});

  @override
  Widget build(BuildContext context) {
    final s = context.getString;
    return _Message(
      icon: Icons.bluetooth_searching_rounded,
      text: s.bt_waiting_for_peer,
      showSpinner: true,
    );
  }
}

// ── Joiner: scan results ────────────────────────────────────────────────────

class _JoinerScan extends StatelessWidget {
  final BluetoothConnectState state;

  const _JoinerScan({required this.state});

  @override
  Widget build(BuildContext context) {
    final s = context.getString;
    final connecting = state.connectingPeerId != null;

    if (state.peers.isEmpty) {
      return _Message(
        icon: Icons.bluetooth_searching_rounded,
        text: s.bt_scanning,
        showSpinner: true,
      );
    }

    return ListView.separated(
      padding: const EdgeInsets.all(16),
      itemCount: state.peers.length,
      separatorBuilder: (_, _) => const SizedBox(height: 8),
      itemBuilder: (context, index) {
        final peer = state.peers[index];
        return _PeerTile(
          peer: peer,
          isConnecting: state.connectingPeerId == peer.id,
          enabled: !connecting,
          connectingLabel: s.bt_connecting,
          onTap: () =>
              context.read<BluetoothConnectCubit>().connectTo(peer),
        );
      },
    );
  }
}

class _PeerTile extends StatelessWidget {
  final BluetoothPeer peer;
  final bool isConnecting;
  final bool enabled;
  final String connectingLabel;
  final VoidCallback onTap;

  const _PeerTile({
    required this.peer,
    required this.isConnecting,
    required this.enabled,
    required this.connectingLabel,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: enabled ? onTap : null,
      child: AnimatedOpacity(
        duration: const Duration(milliseconds: 200),
        opacity: !enabled && !isConnecting ? 0.4 : 1.0,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
          decoration: BoxDecoration(
            color: AppColors.card,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(
              color: isConnecting ? AppColors.amber : AppColors.border,
            ),
          ),
          child: Row(
            children: [
              if (isConnecting)
                SizedBox(
                  width: 20,
                  height: 20,
                  child: CircularProgressIndicator(
                    color: AppColors.amber,
                    strokeWidth: 2,
                  ),
                )
              else
                Icon(Icons.bluetooth_rounded, color: AppColors.amber, size: 20),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  peer.name,
                  style: TextStyle(color: AppColors.textPrimary, fontSize: 14),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              if (isConnecting)
                Text(
                  connectingLabel,
                  style: TextStyle(
                    color: AppColors.amber,
                    fontSize: 11,
                    fontWeight: FontWeight.w600,
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

// ── Shared message state ────────────────────────────────────────────────────

class _Message extends StatelessWidget {
  final IconData icon;
  final String text;
  final bool showSpinner;

  const _Message({required this.icon, required this.text, this.showSpinner = false});

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
            if (showSpinner) ...[
              const SizedBox(height: 20),
              CircularProgressIndicator(color: AppColors.amber),
            ],
          ],
        ),
      ),
    );
  }
}
