import '../entity/transfer_mode.dart';

/// The user's chosen transport (WiFi vs Bluetooth), persisted across app
/// launches. [initialize] must complete before [runApp] so [mode] can be
/// read synchronously by the DI factory that selects which
/// TransferRepository implementation to inject.
abstract interface class TransferModeStore {
  TransferMode get mode;

  Future<void> initialize();

  Future<void> setMode(TransferMode mode);
}
