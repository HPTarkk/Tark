import '../entity/transfer_mode.dart';

/// The transport in effect, persisted across app launches. [initialize] must
/// complete before [runApp] so [mode] can be read synchronously by the DI
/// factory that selects which TransferRepository implementation to inject.
///
/// [mode] chooses the active repository; [pinnedMode] preserves the user's
/// connection preference. Empty legacy preferences mean Wi-Fi/Hotspot.
/// Navigation uses [TransferModePreference.connectionChoice] so a free idle
/// repository after subscription expiry does not change the requested route.
abstract interface class TransferModeStore {
  TransferMode get mode;

  /// Emits every time [setMode] changes the mode — lets a page still alive
  /// further down the nav stack (e.g. Landing, under Settings) react to a
  /// change made elsewhere without polling.
  Stream<TransferMode> get modeChanges;

  /// The explicit preference, or an empty legacy Wi-Fi/Hotspot default.
  TransferMode? get pinnedMode;

  /// Emits on every [setPinnedMode], null included. Separate from
  /// [modeChanges] because a connection preference and its active carrier
  /// answer different questions.
  Stream<TransferMode?> get pinChanges;

  Future<void> initialize();

  Future<void> setMode(TransferMode mode);

  /// Pins a transport. Null remains accepted for legacy Wi-Fi/Hotspot callers.
  ///
  /// Pinning also puts the mode into effect immediately — a picker that
  /// selected a transport the app then went on not to use would be a lie.
  /// Un-pinning deliberately leaves [mode] alone: there is nothing to switch
  /// *to* until the next tap on the landing page names an intent, and
  /// rewriting it here would guess at that.
  Future<void> setPinnedMode(TransferMode? mode);
}

/// User-facing routing follows the connection preference. A free internal
/// repository fallback after subscription expiry must not choose Bluetooth.
extension TransferModePreference on TransferModeStore {
  TransferMode get connectionChoice => pinnedMode ?? TransferMode.wifi;
}
