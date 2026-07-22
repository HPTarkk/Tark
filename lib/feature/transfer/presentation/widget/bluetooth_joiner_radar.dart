import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../../../core/l10n/extension.dart';
import '../../../../core/theme/app_colors.dart';
import '../../domain/entity/bluetooth_peer.dart';
import '../manager/bluetooth_connect_cubit.dart';

/// Joiner screen: rotating radar sweep with discovered peers as blips, plus
/// the tappable peer list below it.
class BluetoothJoinerRadar extends StatefulWidget {
  final BluetoothConnectState state;

  const BluetoothJoinerRadar({super.key, required this.state});

  @override
  State<BluetoothJoinerRadar> createState() => _BluetoothJoinerRadarState();
}

class _BluetoothJoinerRadarState extends State<BluetoothJoinerRadar>
    with SingleTickerProviderStateMixin {
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
          // Escape hatch, mainly for the hands-free auto-reconnect: one tap
          // back to role selection for users who meant to host or pick a
          // different peer this time.
          if (connecting)
            TextButton(
              onPressed: () =>
                  context.read<BluetoothConnectCubit>().backToRoleSelection(),
              child: Text(
                s.cancel,
                style: TextStyle(
                  color: AppColors.textSecondary,
                  fontSize: 11,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 1.5,
                ),
              ),
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
                        onTap: () => context
                            .read<BluetoothConnectCubit>()
                            .connectTo(peer),
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
    canvas.drawLine(
      center.translate(-radius, 0),
      center.translate(radius, 0),
      gridPaint,
    );
    canvas.drawLine(
      center.translate(0, -radius),
      center.translate(0, radius),
      gridPaint,
    );

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
    final edge = Offset(
      center.dx + cos(angle + pi / 2) * radius,
      center.dy + sin(angle + pi / 2) * radius,
    );
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
      final pos = Offset(
        center.dx + cos(bearing) * radius * dist,
        center.dy + sin(bearing) * radius * dist,
      );
      final color = peer.isBle ? amber : green;
      canvas.drawCircle(pos, 7, Paint()..color = color.withAlpha(50));
      canvas.drawCircle(pos, 3.4, Paint()..color = color);
    }

    // Center dot: us.
    canvas.drawCircle(center, 4, Paint()..color = amber);
  }

  @override
  bool shouldRepaint(_RadarPainter old) =>
      old.sweep != sweep || old.peers != peers;
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
                // Amber marks a device hosting from inside the app — the only
                // kind worth tapping, and the only kind the solo auto-join
                // will pick up on its own. Everything else in a classic scan
                // is somebody's headset, so it stays muted.
                Icon(
                  Icons.bluetooth_rounded,
                  color: peer.isAppHost
                      ? AppColors.amber
                      : AppColors.textSecondary,
                  size: 20,
                ),
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
                  style: TextStyle(
                    color: AppColors.amber,
                    fontSize: 11,
                    fontWeight: FontWeight.w600,
                  ),
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
        style: TextStyle(
          color: color,
          fontSize: 8.5,
          fontWeight: FontWeight.w800,
          letterSpacing: 0.8,
        ),
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
