import '../../../transfer/domain/entity/transfer_mode.dart';

/// What a phone chose in settings, as far as a Room is concerned.
///
/// Rooms connect phones running the app, so the settings picker reduces to
/// three answers. Guest is a link to a web browser that can only connect and
/// talk; it says nothing about how two phones should reach each other, so a
/// Room treats it the same as Automatic.
enum RoomTransportChoice {
  automatic,
  bluetooth,

  /// Wi-Fi/Hotspot in the picker.
  hotspot;

  static RoomTransportChoice fromPin(TransferMode? pinned) => switch (pinned) {
    TransferMode.bluetooth => RoomTransportChoice.bluetooth,
    TransferMode.wifi || TransferMode.hotspot => RoomTransportChoice.hotspot,
    TransferMode.guest || null => RoomTransportChoice.automatic,
  };

  /// The pin a Room should honour: the settings pin, minus Guest.
  static TransferMode? roomPin(TransferMode? pinned) =>
      pinned == TransferMode.guest ? null : pinned;

  static RoomTransportChoice? fromKey(Object? key) => switch (key) {
    'automatic' => RoomTransportChoice.automatic,
    'bluetooth' => RoomTransportChoice.bluetooth,
    'hotspot' => RoomTransportChoice.hotspot,
    _ => null,
  };

  String get key => name;

  /// Whether two phones with these choices run their Room over Bluetooth.
  ///
  /// Wi-Fi/Hotspot on either phone wins over Bluetooth on the other, so a
  /// Room only goes over Bluetooth when one phone chose it and the other
  /// chose it too or left it automatic. A phone whose choice is unknown (it
  /// never said) counts as automatic.
  static bool useBluetooth(
    RoomTransportChoice local,
    RoomTransportChoice? peer,
  ) {
    final other = peer ?? RoomTransportChoice.automatic;
    if (local == hotspot || other == hotspot) return false;
    return local == bluetooth || other == bluetooth;
  }
}
