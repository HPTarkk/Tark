/// Unified connection state surfaced by every [TransferRepository]
/// implementation, replacing the old plain `bool` "is connected" signal.
///
/// [down] specifically means "not currently retrying automatically" — either
/// auto-reconnect is turned off, or a transport (Guest/WebRTC) has exhausted
/// its bounded retry attempts — so the UI should offer a manual retry.
enum ConnectionHealthStatus { healthy, reconnecting, down }
