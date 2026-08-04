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

  /// Whether picking this transport needs [PremiumFeature.wifiTransport].
  ///
  /// Written as "anything that isn't Bluetooth" rather than a list of the
  /// three paid modes on purpose: a transport added later is then paid by
  /// default, and shipping a new premium transport for free is the more
  /// expensive mistake of the two. Bluetooth is the free acquisition hook
  /// (business plan §2A) and must stay on this side of the line.
  bool get requiresPremium => this != TransferMode.bluetooth;
}
