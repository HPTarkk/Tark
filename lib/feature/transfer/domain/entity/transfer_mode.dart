enum TransferMode {
  wifi,
  bluetooth,

  /// Android hosts a local Wi-Fi hotspot the iPhone joins (via a Wi-Fi QR /
  /// password), then audio runs over the ordinary Wi-Fi transport. This is
  /// the reliable iPhone↔Android path — BLE is fragile cross-OS. The audio
  /// pipeline is identical to [wifi]; only the connection *setup* differs, so
  /// this mode resolves to the same WifiTransferRepositoryImpl in DI.
  hotspot,

  /// Hosting a browser guest over a serverless WebRTC LAN link.
  guest;

  static TransferMode fromKey(String? key) => switch (key) {
        'bluetooth' => TransferMode.bluetooth,
        'hotspot' => TransferMode.hotspot,
        'guest' => TransferMode.guest,
        _ => TransferMode.wifi,
      };

  String get key => switch (this) {
        TransferMode.wifi => 'wifi',
        TransferMode.bluetooth => 'bluetooth',
        TransferMode.hotspot => 'hotspot',
        TransferMode.guest => 'guest',
      };
}
