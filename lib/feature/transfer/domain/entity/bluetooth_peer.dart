import 'package:equatable/equatable.dart';

/// A nearby Bluetooth device discovered while scanning to join a host.
class BluetoothPeer extends Equatable {
  final String id;
  final String name;

  const BluetoothPeer({required this.id, required this.name});

  @override
  List<Object?> get props => [id, name];
}
