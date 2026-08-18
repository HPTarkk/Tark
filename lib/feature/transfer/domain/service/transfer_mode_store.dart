import '../entity/transfer_mode.dart';

/// The transport in effect, persisted across app launches. [initialize] must
/// complete before [runApp] so [mode] can be read synchronously by the DI
/// factory that selects which TransferRepository implementation to inject.
///
/// Two values, not one, and the distinction is the point:
///
///  * [mode] is what the app is *using*. Something always is, so it is never
///    null, and every path that commits to a transport writes it — including
///    the landing page's automatic choice.
///  * [pinnedMode] is what the user *asked for*, and is null for almost
///    everyone, because automatic is the default. Only Advanced settings
///    writes it.
///
/// Collapsing them would mean automatic had to store a transport to be
/// automatic about, which is how "I picked Wi-Fi once, in a building, in
/// March" becomes a permanent instruction.
abstract interface class TransferModeStore {
  TransferMode get mode;

  /// Emits every time [setMode] changes the mode — lets a page still alive
  /// further down the nav stack (e.g. Landing, under Settings) react to a
  /// change made elsewhere without polling.
  Stream<TransferMode> get modeChanges;

  /// The transport pinned by hand, or null for automatic. Read by
  /// `TransportAdvisor` as the one input that short-circuits its ladder.
  TransferMode? get pinnedMode;

  /// Emits on every [setPinnedMode], null included. Separate from
  /// [modeChanges] because they answer different questions and change at
  /// different rates: under automatic the effective mode moves whenever the
  /// user walks between networks, while the pin does not move at all.
  Stream<TransferMode?> get pinChanges;

  Future<void> initialize();

  Future<void> setMode(TransferMode mode);

  /// Pins a transport, or passes null to go back to automatic.
  ///
  /// Pinning also puts the mode into effect immediately — a picker that
  /// selected a transport the app then went on not to use would be a lie.
  /// Un-pinning deliberately leaves [mode] alone: there is nothing to switch
  /// *to* until the next tap on the landing page names an intent, and
  /// rewriting it here would guess at that.
  Future<void> setPinnedMode(TransferMode? mode);
}
