import 'package:flutter_test/flutter_test.dart';
import 'package:tark/feature/transfer/domain/entity/bluetooth_peer.dart';
import 'package:tark/feature/transfer/domain/service/bluetooth_host_faces.dart';

/// An Android host answers on both radios at once, so the same phone arrives
/// twice — which read as two people and, worse, blocked the hands-free solo
/// join (it refuses to guess between two hosts).
void main() {
  BluetoothPeer classic(String mac, {String name = 'Pedram', int? rssi}) =>
      BluetoothPeer(id: mac, name: name, rssi: rssi, isAppHost: true);

  BluetoothPeer ble(String id, {String name = 'Pedram', int? rssi}) =>
      BluetoothPeer(id: 'ble:$id', name: name, rssi: rssi, isAppHost: true);

  String bleIdForMac(String mac) =>
      '00000000-0000-0000-0000-${mac.replaceAll(':', '').toLowerCase()}';

  group('mergeHostFaces', () {
    test('merges the two radios of one phone by address', () {
      final merged = mergeHostFaces([
        classic('34:2D:0D:59:E1:B2'),
        ble(bleIdForMac('34:2D:0D:59:E1:B2')),
      ]);

      expect(merged, hasLength(1));
      // Classic keeps the id: on Android it is the higher-bandwidth link.
      expect(merged.single.id, '34:2D:0D:59:E1:B2');
      expect(merged.single.isBle, isFalse);
    });

    test('merges by name when the addresses do not line up', () {
      // Android may advertise from a rotating private address, so a mismatch
      // proves nothing.
      final merged = mergeHostFaces([
        classic('34:2D:0D:59:E1:B2', name: 'Pedram'),
        ble('00000000-0000-0000-0000-aabbccddeeff', name: 'pedram'),
      ]);

      expect(merged, hasLength(1));
      expect(merged.single.name, 'Pedram');
    });

    test('claims a nameless BLE host when it is the only ambiguity', () {
      final merged = mergeHostFaces([
        classic('34:2D:0D:59:E1:B2', name: 'Pedram'),
        ble('11111111-2222-3333-4444-555555555555', name: ''),
      ]);

      expect(merged, hasLength(1));
      expect(merged.single.name, 'Pedram');
    });

    test('leaves a nameless BLE host alone when two phones are in range', () {
      // Two classic hosts means two Android phones; the nameless BLE entry
      // could belong to either, or to an iPhone. Guessing would join the
      // wrong person, so the user picks.
      final peers = mergeHostFaces([
        classic('34:2D:0D:59:E1:B2', name: 'Pedram'),
        classic('AA:BB:CC:DD:EE:FF', name: 'Sara'),
        ble('11111111-2222-3333-4444-555555555555', name: ''),
      ]);

      expect(peers, hasLength(3));
    });

    test('keeps two different phones apart', () {
      final peers = mergeHostFaces([
        classic('34:2D:0D:59:E1:B2', name: 'Pedram'),
        ble(bleIdForMac('AA:BB:CC:DD:EE:FF'), name: 'Sara'),
      ]);

      expect(peers, hasLength(2));
    });

    test('never merges two entries from the same radio', () {
      final peers = mergeHostFaces([
        classic('34:2D:0D:59:E1:B2', name: 'Pedram'),
        classic('AA:BB:CC:DD:EE:FF', name: 'Pedram'),
      ]);

      expect(peers, hasLength(2));
    });

    test('keeps the stronger signal of the two faces', () {
      final merged = mergeHostFaces([
        classic('34:2D:0D:59:E1:B2', rssi: -80),
        ble(bleIdForMac('34:2D:0D:59:E1:B2'), rssi: -55),
      ]);

      expect(merged.single.rssi, -55);
    });

    test('passes headsets and TVs through untouched', () {
      const headset = BluetoothPeer(id: 'AA:BB:CC:DD:EE:FF', name: 'WH-1000XM4');
      final peers = mergeHostFaces([
        classic('34:2D:0D:59:E1:B2'),
        ble(bleIdForMac('34:2D:0D:59:E1:B2')),
        headset,
      ]);

      expect(peers, hasLength(2));
      expect(peers, contains(headset));
    });

    test('leaves a single host list alone', () {
      final peers = [classic('34:2D:0D:59:E1:B2')];
      expect(mergeHostFaces(peers), peers);
    });
  });
}
