import '../entity/transfer_mode.dart';

/// The user's chosen transport (WiFi vs Bluetooth), persisted across app
/// launches. [initialize] must complete before [runApp] so [mode] can be
/// read synchronously by the DI factory that selects which
/// TransferRepository implementation to inject.
abstract interface class TransferModeStore {
  TransferMode get mode;

  /// Emits every time [setMode] changes the mode — lets a page still alive
  /// further down the nav stack (e.g. Landing, under Settings) react to a
  /// change made elsewhere without polling.
  Stream<TransferMode> get modeChanges;

  Future<void> initialize();

  Future<void> setMode(TransferMode mode);
}
