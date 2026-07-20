import '../entity/hotspot_credentials.dart';

/// Android host side of the hotspot bridge: brings up a local-only AP and
/// reports OS-initiated teardowns so the UI can re-host.
abstract interface class HotspotHost {
  /// Starts the hotspot and returns its credentials. Throws on failure (or
  /// off Android); callers surface that as an error card.
  Future<HotspotCredentials> start();

  Future<void> stop();

  /// Fires when the OS tears the hotspot down on its own (radio conflict,
  /// Doze, an STA reconnect stealing the single radio) — never for an
  /// app-initiated [stop].
  Stream<void> get onStopped;
}

/// Peer side: programmatically joins the host's network, returning whether
/// the auto-join succeeded (false → the UI falls back to showing the
/// credentials for a manual join).
abstract interface class HotspotJoiner {
  Future<bool> join({required String ssid, required String passphrase});
}
