import 'package:flutter_test/flutter_test.dart';
import 'package:tark/feature/transfer/data/repository/bluetooth_transfer_repository.dart';
import 'package:tark/feature/transfer/domain/entity/bluetooth_connection_state.dart';
import 'package:tark/feature/transfer/domain/entity/connection_health.dart';
import 'package:tark/feature/transfer/domain/repository/transfer_repository.dart';

void main() {
  test('a Room can read the Bluetooth link as it is right now', () {
    // Compiles only while the repository offers a health snapshot. A Room
    // subscribes after the Bluetooth page connected, so it needs the snapshot
    // to learn the link is already up.
    ConnectionHealthSnapshot asSnapshot(BluetoothTransferRepository r) => r;
    expect(asSnapshot, isNotNull);
  });

  test('a connected link reads healthy, a dropped one reconnecting', () {
    expect(
      BluetoothTransferRepository.healthFor(BluetoothConnectionState.connected),
      const ConnectionHealth.healthy(),
    );
    expect(
      BluetoothTransferRepository.healthFor(
        BluetoothConnectionState.reconnecting,
      ),
      const ConnectionHealth.reconnecting(),
    );
    for (final state in [
      BluetoothConnectionState.disconnected,
      BluetoothConnectionState.hosting,
      BluetoothConnectionState.scanning,
      BluetoothConnectionState.connecting,
      BluetoothConnectionState.error,
    ]) {
      expect(
        BluetoothTransferRepository.healthFor(state),
        const ConnectionHealth.down(),
      );
    }
  });
}
