import 'package:flutter/material.dart';

import '../../../../core/l10n/extension.dart';
import '../../../../core/theme/app_colors.dart';
import '../manager/bluetooth_connect_cubit.dart';
import 'bluetooth_wifi_bridge_hint.dart';

/// Host waiting screen: pulsing beacon ripples while advertising for a peer.
class BluetoothHostBeacon extends StatefulWidget {
  final BluetoothConnectState state;

  const BluetoothHostBeacon({super.key, required this.state});

  @override
  State<BluetoothHostBeacon> createState() => _BluetoothHostBeaconState();
}

class _BluetoothHostBeaconState extends State<BluetoothHostBeacon>
    with SingleTickerProviderStateMixin {
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
                painter: _BeaconPainter(
                  t: _ripple.value,
                  color: AppColors.amber,
                ),
                child: Center(
                  child: Container(
                    width: 76,
                    height: 76,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: AppColors.amber.withAlpha(30),
                      border: Border.all(color: AppColors.amber.withAlpha(170)),
                      boxShadow: [
                        BoxShadow(
                          color: AppColors.amber.withAlpha(70),
                          blurRadius: 24,
                        ),
                      ],
                    ),
                    child: Icon(
                      Icons.podcasts_rounded,
                      color: AppColors.amber,
                      size: 34,
                    ),
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
              child: BluetoothWifiBridgeHint(message: s.bt_ble_unavailable),
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
                    style: TextStyle(
                      color: AppColors.amber,
                      fontSize: 13,
                      fontWeight: FontWeight.w800,
                    ),
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
