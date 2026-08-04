/// Every capability the business plan places behind a paid tier.
///
/// Adding a value here is the *only* way a feature becomes premium — nothing
/// in the app asks "is the user subscribed" directly, it asks
/// `LicenseGate.allows(...)` about one of these. Keeps the paid surface
/// enumerable: this enum is the whole answer to "what does money buy".
enum PremiumFeature {
  /// Wi-Fi, Hotspot and Guest transports. Bluetooth is deliberately absent —
  /// it is the permanently free acquisition hook and must never appear here.
  wifiTransport,

  /// Muting your own mic mid-session (walkie page + the Android home widget).
  selfMute,

  /// Playing music into the channel while a session is live.
  musicPlayback,
}
