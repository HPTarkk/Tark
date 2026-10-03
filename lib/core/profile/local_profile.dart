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

  /// Whether this person's subscription is running right now, so others in
  /// the room can show a premium mark on them. A function rather than a
  /// value because a subscription can end with no event to say so; the
  /// subscription service installs the real one at startup.
  ///
  /// Display only, and taken on trust from whoever sends it: it never
  /// unlocks anything on the phone that receives it.
  static bool Function() isPremium = _never;

  static bool _never() => false;
}
