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

  /// Opens the system screen where the user can fix a [start] failure —
  /// Location for `location_off`, tethering for `tethering_on`. No-op where
  /// the screen doesn't exist.
  Future<void> openFixSettings(String errorCode);
}

/// Peer side: programmatically joins the host's network, returning whether
/// the auto-join succeeded (false → the UI falls back to showing the
/// credentials for a manual join).
abstract interface class HotspotJoiner {
  Future<bool> join(HotspotCredentials credentials);

  /// Pins this process's sockets to the Wi-Fi the user joined by hand, for the
  /// manual fallback. Returns whether a Wi-Fi network was there to bind to.
  /// Without it, Android drops back to cellular the moment it notices the
  /// hotspot has no internet and the session goes quiet (Android only; a no-op
  /// elsewhere).
  Future<bool> bindToCurrentWifi();

  /// Releases the joined network and unbinds the process. Call when leaving
  /// the bridge WITHOUT entering the channel — the live session runs over it.
  Future<void> leave();

  /// Fires when the joined network goes away (the host's AP died or moved out
  /// of range), so the peer can re-scan instead of sitting on a dead link.
  Stream<void> get onLost;
}
