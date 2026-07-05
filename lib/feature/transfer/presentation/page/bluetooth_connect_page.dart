import 'dart:io';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:get_it/get_it.dart';
import 'package:go_router/go_router.dart';
import 'package:permission_handler/permission_handler.dart';

import '../../../../core/l10n/extension.dart';
import '../../../../core/router/routes.dart';
import '../../../../core/theme/app_colors.dart';
import '../../domain/entity/bluetooth_connection_state.dart';
import '../../domain/entity/bluetooth_peer.dart';
import '../../domain/entity/bluetooth_role.dart';
import '../../domain/entity/transfer_mode.dart';
import '../../domain/service/transfer_mode_store.dart';
import '../manager/bluetooth_connect_cubit.dart';

/// Tears down the Bluetooth session, switches the active transport to the
/// Wi-Fi hotspot bridge, and navigates there — the escape hatch for
/// iPhone↔Android pairs where Bluetooth is flaky.
Future<void> _switchToHotspot(BuildContext context) async {
  context.read<BluetoothConnectCubit>().backToRoleSelection();
  await GetIt.instance<TransferModeStore>().setMode(TransferMode.hotspot);
  if (context.mounted) context.goNamed(AppRoutes.hotspotBridgeName);
}

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
            } else {
              context.pop();
            }
          },
        ),
        title: Text(s.transport_bluetooth, style: TextStyle(color: AppColors.textPrimary, fontSize: 16)),
      ),
      body: SafeArea(
        child: Align(
          alignment: Alignment.topCenter,
          child: BlocConsumer<BluetoothConnectCubit, BluetoothConnectState>(
            listener: (context, state) async {
              if (state.connectionState == BluetoothConnectionState.connected && !_navigatingToWalkie) {
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
                return _Message(icon: Icons.bluetooth_disabled_rounded, text: s.bt_not_supported_platform);
              }
              if (_permissionDenied) {
                return _PermissionDenied(onOpenSettings: openAppSettings, onRetry: _ensurePermissions);
              }
              if (state.connectionState == BluetoothConnectionState.connected || _navigatingToWalkie) {
                return const _ConnectedFlash();
              }
              if (state.connectionState == BluetoothConnectionState.error) {
                return _ErrorCard(onRetry: () => context.read<BluetoothConnectCubit>().backToRoleSelection());
              }
              if (state.role == null) {
                return _RoleSelection(onEnsurePermissions: _ensurePermissions);
              }
              if (state.role == BluetoothRole.host) {
                return _HostBeacon(state: state);
              }
              return _JoinerRadar(state: state);
            },
          ),
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
    final lastPeer = context.select((BluetoothConnectCubit c) => c.state.lastPeer);
    return ListView(
      padding: const EdgeInsets.all(24),
      children: [
        const SizedBox(height: 12),
        _Entrance(
          delayMs: 0,
          child: _RoleCard(
            icon: Icons.podcasts_rounded,
            title: s.bt_start_session,
            description: s.bt_role_host_desc,
            onTap: () async {
              if (!await onEnsurePermissions()) return;
              if (!context.mounted) return;
              context.read<BluetoothConnectCubit>().startHosting();
            },
          ),
        ),
        const SizedBox(height: 14),
        _Entrance(
          delayMs: 90,
          child: _RoleCard(
            icon: Icons.radar_rounded,
            title: s.bt_find_nearby,
            description: s.bt_role_join_desc,
            onTap: () async {
              if (!await onEnsurePermissions()) return;
              if (!context.mounted) return;
              context.read<BluetoothConnectCubit>().startScanning();
            },
          ),
        ),
        if (lastPeer != null) ...[
          const SizedBox(height: 22),
          _Entrance(
            delayMs: 180,
            child: _ReconnectCard(
              peer: lastPeer,
              onTap: () async {
                if (!await onEnsurePermissions()) return;
                if (!context.mounted) return;
                context.read<BluetoothConnectCubit>().reconnectToLast();
              },
            ),
          ),
        ],
        const SizedBox(height: 26),
        _Entrance(
          delayMs: lastPeer != null ? 270 : 180,
          child: _WifiBridgeHint(message: s.bt_ios_hint),
        ),
      ],
    );
  }
}

/// Cross-OS nudge: Bluetooth between iPhone and Android is unreliable, so this
/// offers a one-tap jump to the Wi-Fi hotspot bridge. Shown as always-on
/// guidance on the role screen and as a recovery card when BLE advertising
/// couldn't start while hosting.
class _WifiBridgeHint extends StatelessWidget {
  final String message;

  const _WifiBridgeHint({required this.message});

  @override
  Widget build(BuildContext context) {
    final s = context.getString;
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: AppColors.amber.withAlpha(14),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: AppColors.amber.withAlpha(70)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.phone_iphone_rounded, color: AppColors.amber, size: 18),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  message,
                  style: TextStyle(color: AppColors.textSecondary, fontSize: 11.5, height: 1.45),
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          GestureDetector(
            onTap: () => _switchToHotspot(context),
            child: Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(vertical: 12),
              decoration: BoxDecoration(
                color: AppColors.amber.withAlpha(25),
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: AppColors.amber.withAlpha(120), width: 1.5),
              ),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(Icons.wifi_tethering_rounded, color: AppColors.amber, size: 16),
                  const SizedBox(width: 8),
                  Text(
                    s.bt_use_wifi_bridge,
                    style: TextStyle(
                      color: AppColors.amber,
                      fontSize: 11.5,
                      fontWeight: FontWeight.w800,
                      letterSpacing: 1.2,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _RoleCard extends StatelessWidget {
  final IconData icon;
  final String title;
  final String description;
  final VoidCallback onTap;

  const _RoleCard({required this.icon, required this.title, required this.description, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.all(18),
        decoration: BoxDecoration(
          color: AppColors.card,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: AppColors.border, width: 1.5),
        ),
        child: Row(
          children: [
            Container(
              width: 52,
              height: 52,
              decoration: BoxDecoration(
                color: AppColors.amber.withAlpha(22),
                borderRadius: BorderRadius.circular(14),
                border: Border.all(color: AppColors.amber.withAlpha(110)),
              ),
              child: Icon(icon, color: AppColors.amber, size: 26),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: TextStyle(
                      color: AppColors.textPrimary,
                      fontSize: 14,
                      fontWeight: FontWeight.w800,
                      letterSpacing: 1.2,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    description,
                    style: TextStyle(color: AppColors.textSecondary, fontSize: 11.5, height: 1.4),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            Icon(
              Icons.chevron_right_rounded,
              color: AppColors.textSecondary,
              textDirection: Directionality.of(context),
            ),
          ],
        ),
      ),
    );
  }
}

class _ReconnectCard extends StatelessWidget {
  final BluetoothPeer peer;
  final VoidCallback onTap;

  const _ReconnectCard({required this.peer, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final s = context.getString;
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: AppColors.green.withAlpha(12),
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: AppColors.green.withAlpha(90), width: 1.5),
        ),
        child: Row(
          children: [
            Icon(Icons.history_rounded, color: AppColors.green, size: 22),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    s.bt_last_session,
                    style: TextStyle(
                      color: AppColors.textSecondary,
                      fontSize: 10,
                      fontWeight: FontWeight.w700,
                      letterSpacing: 2,
                    ),
                  ),
                  const SizedBox(height: 3),
                  Text(
                    peer.name,
                    style: TextStyle(color: AppColors.textPrimary, fontSize: 14, fontWeight: FontWeight.w700),
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
              ),
            ),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
              decoration: BoxDecoration(
                color: AppColors.green.withAlpha(26),
                borderRadius: BorderRadius.circular(9),
                border: Border.all(color: AppColors.green.withAlpha(140)),
              ),
              child: Text(
                s.bt_reconnect,
                style: TextStyle(
                  color: AppColors.green,
                  fontSize: 11,
                  fontWeight: FontWeight.w800,
                  letterSpacing: 1.2,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ── Host: pulsing beacon ────────────────────────────────────────────────────

class _HostBeacon extends StatefulWidget {
  final BluetoothConnectState state;

  const _HostBeacon({required this.state});

  @override
  State<_HostBeacon> createState() => _HostBeaconState();
}

class _HostBeaconState extends State<_HostBeacon> with SingleTickerProviderStateMixin {
  late final AnimationController _ripple = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 2400),
  )..repeat();

  @override
  void dispose() {
    _ripple.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final s = context.getString;
    return Align(
      alignment: AlignmentDirectional.topCenter,
      child: Column(
        children: [
          const Spacer(),
          SizedBox(
            width: 240,
            height: 240,
            child: AnimatedBuilder(
              animation: _ripple,
              builder: (context, _) => CustomPaint(
                painter: _BeaconPainter(t: _ripple.value, color: AppColors.amber),
                child: Center(
                  child: Container(
                    width: 76,
                    height: 76,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: AppColors.amber.withAlpha(30),
                      border: Border.all(color: AppColors.amber.withAlpha(170)),
                      boxShadow: [BoxShadow(color: AppColors.amber.withAlpha(70), blurRadius: 24)],
                    ),
                    child: Icon(Icons.podcasts_rounded, color: AppColors.amber, size: 34),
                  ),
                ),
              ),
            ),
          ),
          const SizedBox(height: 28),
          Text(
            s.bt_waiting_for_peer,
            textAlign: TextAlign.center,
            style: TextStyle(color: AppColors.textSecondary, fontSize: 14),
          ),
          if (widget.state.bleUnavailable) ...[
            const SizedBox(height: 18),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 24),
              child: _WifiBridgeHint(message: s.bt_ble_unavailable),
            ),
          ],
          const SizedBox(height: 18),
          if (widget.state.myName.isNotEmpty)
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 9),
              decoration: BoxDecoration(
                color: AppColors.card,
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: AppColors.border),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    s.bt_visible_as,
                    style: TextStyle(
                      color: AppColors.textSecondary,
                      fontSize: 10,
                      fontWeight: FontWeight.w700,
                      letterSpacing: 1.5,
                    ),
                  ),
                  const SizedBox(width: 8),
                  Text(
                    widget.state.myName,
                    style: TextStyle(color: AppColors.amber, fontSize: 13, fontWeight: FontWeight.w800),
                  ),
                ],
              ),
            ),
          const Spacer(),
        ],
      ),
    );
  }
}

class _BeaconPainter extends CustomPainter {
  final double t;
  final Color color;

  _BeaconPainter({required this.t, required this.color});

  @override
  void paint(Canvas canvas, Size size) {
    final center = size.center(Offset.zero);
    final maxRadius = size.shortestSide / 2;
    for (var k = 0; k < 3; k++) {
      final phase = (t + k / 3) % 1.0;
      final radius = 40 + phase * (maxRadius - 40);
      final alpha = ((1 - phase) * 110).toInt();
      canvas.drawCircle(
        center,
        radius,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.6
          ..color = color.withAlpha(alpha),
      );
    }
  }

  @override
  bool shouldRepaint(_BeaconPainter old) => old.t != t;
}

// ── Joiner: radar scan ──────────────────────────────────────────────────────

class _JoinerRadar extends StatefulWidget {
  final BluetoothConnectState state;

  const _JoinerRadar({required this.state});

  @override
  State<_JoinerRadar> createState() => _JoinerRadarState();
}

class _JoinerRadarState extends State<_JoinerRadar> with SingleTickerProviderStateMixin {
  late final AnimationController _sweep = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 3600),
  )..repeat();

  @override
  void dispose() {
    _sweep.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final s = context.getString;
    final state = widget.state;
    final connecting = state.connectingPeerId != null;
    final connectingPeer = connecting
        ? state.peers.where((p) => p.id == state.connectingPeerId).firstOrNull
        : null;

    return Align(
      alignment: AlignmentDirectional.topCenter,
      child: Column(
        children: [
          const SizedBox(height: 8),
          SizedBox(
            width: 210,
            height: 210,
            child: AnimatedBuilder(
              animation: _sweep,
              builder: (context, _) => CustomPaint(
                painter: _RadarPainter(
                  sweep: _sweep.value,
                  peers: state.peers,
                  amber: AppColors.amber,
                  grid: AppColors.border,
                  green: AppColors.green,
                ),
              ),
            ),
          ),
          const SizedBox(height: 14),
          Text(
            connecting
                ? '${s.bt_connecting} ${connectingPeer?.name ?? state.lastPeer?.name ?? ''}'
                : s.bt_scanning,
            style: TextStyle(color: AppColors.textSecondary, fontSize: 13),
          ),
          const SizedBox(height: 14),
          Expanded(
            child: state.peers.isEmpty
                ? const SizedBox.shrink()
                : ListView.separated(
                    padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                    itemCount: state.peers.length,
                    separatorBuilder: (_, _) => const SizedBox(height: 8),
                    itemBuilder: (context, index) {
                      final peer = state.peers[index];
                      return _PeerTile(
                        peer: peer,
                        isConnecting: state.connectingPeerId == peer.id,
                        enabled: !connecting,
                        connectingLabel: s.bt_connecting,
                        onTap: () => context.read<BluetoothConnectCubit>().connectTo(peer),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }
}

class _RadarPainter extends CustomPainter {
  final double sweep;
  final List<BluetoothPeer> peers;
  final Color amber;
  final Color grid;
  final Color green;

  _RadarPainter({
    required this.sweep,
    required this.peers,
    required this.amber,
    required this.grid,
    required this.green,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final center = size.center(Offset.zero);
    final radius = size.shortestSide / 2;

    // Grid: three rings + cross hairs.
    final gridPaint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1
      ..color = grid;
    for (final f in [1.0, 0.66, 0.33]) {
      canvas.drawCircle(center, radius * f, gridPaint);
    }
    canvas.drawLine(center.translate(-radius, 0), center.translate(radius, 0), gridPaint);
    canvas.drawLine(center.translate(0, -radius), center.translate(0, radius), gridPaint);

    // Rotating sweep wedge with a fading tail.
    final angle = sweep * 2 * pi;
    final rect = Rect.fromCircle(center: center, radius: radius);
    canvas.save();
    canvas.translate(center.dx, center.dy);
    canvas.rotate(angle);
    canvas.translate(-center.dx, -center.dy);
    final wedge = Paint()
      ..shader = SweepGradient(
        center: Alignment.center,
        startAngle: 0,
        endAngle: pi / 2,
        colors: [amber.withAlpha(0), amber.withAlpha(70)],
      ).createShader(rect);
    canvas.drawPath(
      Path()
        ..moveTo(center.dx, center.dy)
        ..arcTo(rect, 0, pi / 2, false)
        ..close(),
      wedge,
    );
    canvas.restore();

    // Leading edge of the sweep.
    final edge = Offset(center.dx + cos(angle + pi / 2) * radius, center.dy + sin(angle + pi / 2) * radius);
    canvas.drawLine(
      center,
      edge,
      Paint()
        ..strokeWidth = 1.6
        ..color = amber.withAlpha(150),
    );

    // Peers as glowing blips: bearing from the id (stable), distance from
    // signal strength (stronger = closer to center).
    for (final peer in peers) {
      final bearing = (peer.id.hashCode % 360) * pi / 180;
      final rssi = peer.rssi ?? -78;
      final dist = (((-rssi) - 45) / 50).clamp(0.18, 0.92);
      final pos = Offset(center.dx + cos(bearing) * radius * dist, center.dy + sin(bearing) * radius * dist);
      final color = peer.isBle ? amber : green;
      canvas.drawCircle(pos, 7, Paint()..color = color.withAlpha(50));
      canvas.drawCircle(pos, 3.4, Paint()..color = color);
    }

    // Center dot: us.
    canvas.drawCircle(center, 4, Paint()..color = amber);
  }

  @override
  bool shouldRepaint(_RadarPainter old) => old.sweep != sweep || old.peers != peers;
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
            border: Border.all(color: isConnecting ? AppColors.amber : AppColors.border),
          ),
          child: Row(
            children: [
              if (isConnecting)
                SizedBox(
                  width: 20,
                  height: 20,
                  child: CircularProgressIndicator(color: AppColors.amber, strokeWidth: 2),
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
              const SizedBox(width: 8),
              _TransportBadge(isBle: peer.isBle),
              const SizedBox(width: 10),
              _SignalBars(bars: peer.signalBars),
              if (isConnecting) ...[
                const SizedBox(width: 10),
                Text(
                  connectingLabel,
                  style: TextStyle(color: AppColors.amber, fontSize: 11, fontWeight: FontWeight.w600),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class _TransportBadge extends StatelessWidget {
  final bool isBle;

  const _TransportBadge({required this.isBle});

  @override
  Widget build(BuildContext context) {
    final color = isBle ? AppColors.amber : AppColors.green;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: color.withAlpha(20),
        borderRadius: BorderRadius.circular(5),
        border: Border.all(color: color.withAlpha(110), width: 0.8),
      ),
      child: Text(
        isBle ? 'BLE' : 'BT',
        style: TextStyle(color: color, fontSize: 8.5, fontWeight: FontWeight.w800, letterSpacing: 0.8),
      ),
    );
  }
}

class _SignalBars extends StatelessWidget {
  final int bars; // 0..4

  const _SignalBars({required this.bars});

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.end,
      children: [
        for (var i = 0; i < 4; i++) ...[
          if (i > 0) const SizedBox(width: 2),
          AnimatedContainer(
            duration: const Duration(milliseconds: 300),
            width: 3,
            height: 5.0 + i * 3,
            decoration: BoxDecoration(
              color: i < bars ? AppColors.amber : AppColors.border,
              borderRadius: BorderRadius.circular(1),
            ),
          ),
        ],
      ],
    );
  }
}

// ── Connected flash ─────────────────────────────────────────────────────────

class _ConnectedFlash extends StatelessWidget {
  const _ConnectedFlash();

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
            builder: (context, scale, child) => Transform.scale(scale: scale, child: child),
            child: Container(
              width: 84,
              height: 84,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: AppColors.green.withAlpha(26),
                border: Border.all(color: AppColors.green, width: 2),
                boxShadow: [BoxShadow(color: AppColors.green.withAlpha(70), blurRadius: 26)],
              ),
              child: Icon(Icons.check_rounded, color: AppColors.green, size: 42),
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

// ── Error ───────────────────────────────────────────────────────────────────

class _ErrorCard extends StatelessWidget {
  final VoidCallback onRetry;

  const _ErrorCard({required this.onRetry});

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
                padding: const EdgeInsets.symmetric(horizontal: 26, vertical: 12),
                decoration: BoxDecoration(
                  color: AppColors.amber.withAlpha(25),
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: AppColors.amber.withAlpha(120), width: 1.5),
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

// ── Permission denied ───────────────────────────────────────────────────────

class _PermissionDenied extends StatelessWidget {
  final Future<void> Function() onOpenSettings;
  final Future<void> Function() onRetry;

  const _PermissionDenied({required this.onOpenSettings, required this.onRetry});

  @override
  Widget build(BuildContext context) {
    final s = context.getString;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.bluetooth_disabled_rounded, color: AppColors.amber, size: 40),
            const SizedBox(height: 16),
            Text(
              s.bt_permission_denied,
              textAlign: TextAlign.center,
              style: TextStyle(color: AppColors.textSecondary, fontSize: 14),
            ),
            const SizedBox(height: 24),
            GestureDetector(
              onTap: () => onOpenSettings(),
              child: Container(
                width: double.infinity,
                padding: const EdgeInsets.symmetric(vertical: 16),
                decoration: BoxDecoration(
                  color: AppColors.amber.withAlpha(25),
                  borderRadius: BorderRadius.circular(14),
                  border: Border.all(color: AppColors.amber.withAlpha(120), width: 2),
                ),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(Icons.settings_rounded, color: AppColors.amber, size: 20),
                    const SizedBox(width: 10),
                    Text(
                      s.open_settings,
                      style: TextStyle(
                        color: AppColors.amber,
                        fontSize: 13,
                        fontWeight: FontWeight.w800,
                        letterSpacing: 1.5,
                      ),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 8),
            TextButton(
              onPressed: () => onRetry(),
              child: Text(
                s.retry,
                style: TextStyle(
                  color: AppColors.textSecondary,
                  fontSize: 13,
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

// ── Shared bits ─────────────────────────────────────────────────────────────

/// Small fade+slide entrance used by the role cards.
class _Entrance extends StatefulWidget {
  final Widget child;
  final int delayMs;

  const _Entrance({required this.child, required this.delayMs});

  @override
  State<_Entrance> createState() => _EntranceState();
}

class _EntranceState extends State<_Entrance> with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 420),
  );
  late final CurvedAnimation _anim = CurvedAnimation(parent: _controller, curve: Curves.easeOutCubic);

  @override
  void initState() {
    super.initState();
    Future.delayed(Duration(milliseconds: widget.delayMs), () {
      if (mounted) _controller.forward();
    });
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _anim,
      child: widget.child,
      builder: (context, child) => Opacity(
        opacity: _anim.value,
        child: Transform.translate(offset: Offset(0, 18 * (1 - _anim.value)), child: child),
      ),
    );
  }
}

class _Message extends StatelessWidget {
  final IconData icon;
  final String text;

  const _Message({required this.icon, required this.text});

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
