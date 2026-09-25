import 'package:flutter_test/flutter_test.dart';
import 'package:tark/feature/transfer/data/bluetooth/classic_bluetooth_engine.dart';

void main() {
  group('ClassicBluetoothEngine.hostReady', () {
    test('a plain host is ready once its listener is up', () {
      // The Bluetooth screen has no Room invite, so there is no rendezvous
      // advertisement to wait for. Requiring one sent Start straight back to
      // the role picker.
      expect(
        ClassicBluetoothEngine.hostReady(const {
          'serverListening': true,
          'bleAdvertising': false,
        }, rendezvous: false),
        isTrue,
      );
    });

    test('a Room host also needs its rendezvous advertisement', () {
      expect(
        ClassicBluetoothEngine.hostReady(const {
          'serverListening': true,
          'bleAdvertising': false,
        }, rendezvous: true),
        isFalse,
      );
      expect(
        ClassicBluetoothEngine.hostReady(const {
          'serverListening': true,
          'bleAdvertising': true,
        }, rendezvous: true),
        isTrue,
      );
    });

    test('no listener is never ready', () {
      for (final rendezvous in [true, false]) {
        expect(
          ClassicBluetoothEngine.hostReady(null, rendezvous: rendezvous),
          isFalse,
        );
        expect(
          ClassicBluetoothEngine.hostReady(const {
            'serverListening': false,
            'bleAdvertising': true,
          }, rendezvous: rendezvous),
          isFalse,
        );
      }
    });
  });
}
