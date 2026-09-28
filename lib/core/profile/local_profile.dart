/// The parts of this person's profile that ride along on the wire.
///
/// Process-wide on purpose, like `AudioCapabilityNegotiator.localBitmask`:
/// every transport's presence packet reads it at encode time, so the
/// Bluetooth hello, the Room pre-live announcer and the channel's own
/// presence tick all carry the current avatar without each caller having to
/// thread it through. Kept in step with storage by [SettingsRepository]
/// (seeded at startup, updated on every save).
abstract final class LocalProfile {
  /// The picked avatar id, or null when none has been picked.
  static int? avatarId;
}
