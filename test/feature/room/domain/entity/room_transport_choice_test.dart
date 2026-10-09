import 'package:flutter_test/flutter_test.dart';
import 'package:tark/feature/room/domain/entity/room_transport_choice.dart';
import 'package:tark/feature/transfer/domain/entity/transfer_mode.dart';

void main() {
  test(
    'the settings pin uses Wi-Fi by default and Bluetooth only explicitly',
    () {
      expect(
        RoomTransportChoice.fromPin(TransferMode.bluetooth),
        RoomTransportChoice.bluetooth,
      );
      expect(
        RoomTransportChoice.fromPin(TransferMode.wifi),
        RoomTransportChoice.hotspot,
      );
      expect(
        RoomTransportChoice.fromPin(TransferMode.hotspot),
        RoomTransportChoice.hotspot,
      );
      // Legacy automatic and Guest preferences use Wi-Fi for Rooms.
      expect(
        RoomTransportChoice.fromPin(TransferMode.guest),
        RoomTransportChoice.hotspot,
      );
      expect(RoomTransportChoice.fromPin(null), RoomTransportChoice.hotspot);
      expect(
        RoomTransportChoice.roomPin(TransferMode.guest),
        TransferMode.wifi,
      );
      expect(RoomTransportChoice.roomPin(null), TransferMode.wifi);
      expect(
        RoomTransportChoice.roomPin(TransferMode.bluetooth),
        TransferMode.bluetooth,
      );
    },
  );

  test('Wi-Fi/Hotspot wins, then Bluetooth, then the default hotspot', () {
    const a = RoomTransportChoice.automatic;
    const b = RoomTransportChoice.bluetooth;
    const h = RoomTransportChoice.hotspot;
    final cases = {
      (b, b): true,
      (b, a): true,
      (a, b): true,
      (b, null): true,
      (b, h): false,
      (h, b): false,
      (a, a): false,
      (a, null): false,
      (h, h): false,
    };
    cases.forEach((pair, expected) {
      expect(
        RoomTransportChoice.useBluetooth(pair.$1, pair.$2),
        expected,
        reason: '$pair',
      );
    });
  });

  test('keys survive the trip over the invite link', () {
    for (final choice in RoomTransportChoice.values) {
      expect(RoomTransportChoice.fromKey(choice.key), choice);
    }
    expect(RoomTransportChoice.fromKey('guest'), isNull);
    expect(RoomTransportChoice.fromKey(true), isNull);
  });
}
