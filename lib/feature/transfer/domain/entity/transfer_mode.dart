enum TransferMode {
  wifi,
  bluetooth,

  /// Hosting a browser guest over a serverless WebRTC LAN link.
  guest;

  static TransferMode fromKey(String? key) => switch (key) {
        'bluetooth' => TransferMode.bluetooth,
        'guest' => TransferMode.guest,
        _ => TransferMode.wifi,
      };

  String get key => switch (this) {
        TransferMode.wifi => 'wifi',
        TransferMode.bluetooth => 'bluetooth',
        TransferMode.guest => 'guest',
      };
}
