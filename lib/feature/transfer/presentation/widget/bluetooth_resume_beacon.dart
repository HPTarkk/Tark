import 'package:flutter/material.dart';
import 'bluetooth_signal_scene.dart';

/// Cold-start search uses the same radio language as manual pairing.
class BluetoothResumeBeacon extends StatelessWidget {
  const BluetoothResumeBeacon({super.key, required this.countdown});
  final Animation<double> countdown;
  @override
  Widget build(BuildContext context) => BluetoothSignalScene(
    phase: BluetoothSignalPhase.searching,
    countdown: countdown,
  );
}
