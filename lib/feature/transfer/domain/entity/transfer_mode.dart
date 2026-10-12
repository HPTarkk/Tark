import '../../../../core/beta/beta_feature.dart';

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
  /// An exhaustive switch rather than a default on purpose: a transport added
  /// later does not compile until someone decides which side of the paid line
  /// it sits on. Bluetooth is the free acquisition hook (business plan §2A)
  /// and must stay free. Guest is free too — it ships as a [BetaFeature]
  /// (see [betaFeature]), and charging for something we openly call
  /// experimental would be the wrong promise.
  bool get requiresPremium => switch (this) {
    TransferMode.wifi || TransferMode.hotspot => true,
    TransferMode.bluetooth || TransferMode.guest => false,
  };

  /// The beta classification this transport ships under, or null when it is
  /// a finished, production path. Every surface that offers or names a
  /// transport asks this, so the Beta mark appears wherever Guest does.
  BetaFeature? get betaFeature => switch (this) {
    TransferMode.guest => BetaFeature.guestConnection,
    TransferMode.wifi || TransferMode.hotspot || TransferMode.bluetooth => null,
  };
}
