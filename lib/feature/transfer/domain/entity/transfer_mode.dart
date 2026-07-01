enum TransferMode {
  wifi,
  bluetooth;

  static TransferMode fromKey(String? key) => switch (key) {
        'bluetooth' => TransferMode.bluetooth,
        _ => TransferMode.wifi,
      };

  String get key => switch (this) {
        TransferMode.wifi => 'wifi',
        TransferMode.bluetooth => 'bluetooth',
      };
}
