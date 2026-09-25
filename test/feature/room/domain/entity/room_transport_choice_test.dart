import 'package:flutter_test/flutter_test.dart';
import 'package:tark/feature/room/domain/entity/room_transport_choice.dart';
import 'package:tark/feature/transfer/domain/entity/transfer_mode.dart';

void main() {
  test('the settings pin maps onto three Room choices', () {
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
    // Guest is a browser that only connects and talks: automatic for Rooms.
    expect(
      RoomTransportChoice.fromPin(TransferMode.guest),
      RoomTransportChoice.automatic,
    );
    expect(RoomTransportChoice.fromPin(null), RoomTransportChoice.automatic);
    expect(RoomTransportChoice.roomPin(TransferMode.guest), isNull);
    expect(
      RoomTransportChoice.roomPin(TransferMode.bluetooth),
      TransferMode.bluetooth,
    );
  });

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
