import 'package:flutter_test/flutter_test.dart';
import 'package:tark/feature/transfer/domain/entity/bluetooth_peer.dart';
import 'package:tark/feature/transfer/domain/service/bluetooth_host_filter.dart';

/// A classic inquiry reports every headset, TV and laptop in radio range, and
/// the joiner list used to show all of them — unjoinable devices padding a list
/// meant to be a list of people. Only the app's own hosts belong there now,
/// with one exception that has to survive: the remembered host an auto-reconnect
/// is re-dialing, which Android may still be naming from a stale cache.
void main() {
  BluetoothPeer peer(String id, {bool isAppHost = false}) =>
      BluetoothPeer(id: id, name: 'whatever', isAppHost: isAppHost);

  test('a device hosting from inside the app is shown', () {
    expect(isVisibleHost(peer('AA:BB:CC:DD:EE:FF', isAppHost: true)), isTrue);
  });

  test('somebody else\'s headset is not', () {
    expect(isVisibleHost(peer('11:22:33:44:55:66')), isFalse);
  });

  test('the reconnect target is shown even when it reads as a stranger', () {
    const mac = '11:22:33:44:55:66';
    expect(isVisibleHost(peer(mac), reconnectTargetId: mac), isTrue);
  });

  test('a reconnect target does not admit every other device with it', () {
    expect(
      isVisibleHost(
        peer('11:22:33:44:55:66'),
        reconnectTargetId: 'AA:BB:CC:DD:EE:FF',
      ),
      isFalse,
    );
  });

  test('no reconnect target in flight admits nothing extra', () {
    expect(
      isVisibleHost(peer('11:22:33:44:55:66'), reconnectTargetId: null),
      isFalse,
    );
  });
}
