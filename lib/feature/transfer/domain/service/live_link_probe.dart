import '../entity/live_link.dart';

/// Reads whether this device has a link at all, without starting one.
///
/// Deliberately separate from `TransferRepository.connect()`: that opens a
/// session and then reports how it is doing, which is the wrong shape for the
/// question asked *before* a channel exists. Nothing here transmits, binds a
/// socket, raises an access point or touches the microphone — a screen may
/// ask as often as it likes.
abstract interface class LiveLinkProbe {
  /// Every link that is up right now. Never throws: a radio that cannot be
  /// read reports itself as down, because "we could not tell" and "there is
  /// nothing there" lead to the same safe screen, while guessing the other
  /// way puts someone into a channel with nobody on the end of it.
  Future<LiveLinkSnapshot> read();

  /// Fires when something about the link may have changed, so a screen
  /// showing the answer can go and get it again. Carries no value on purpose
  /// — the reader is [read], and a stream that also answered would be a
  /// second source of the same truth.
  Stream<void> get changes;
}
