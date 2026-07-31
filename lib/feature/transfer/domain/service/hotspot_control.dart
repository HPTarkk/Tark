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

/// How a [HotspotJoiner.join] ended. [declined] and [wifiOff] both mean "not
/// on the network", but they need opposite screens: one is a dead end the user
/// works around by joining in Settings, the other is a switch they can flip.
/// Collapsing them into a bare false sent a phone with its Wi-Fi off to the
/// manual card, which tells you to pick the network from a Wi-Fi list that
/// isn't scanning.
enum HotspotJoinResult {
  /// Associated and pinned to the host's network.
  joined,

  /// The Wi-Fi radio is off, so no join of any kind can happen yet.
  wifiOff,

  /// The system Location toggle is off. Through Android 12 that stops Wi-Fi
  /// scanning outright, so the framework's network picker finds nothing and
  /// gives up ~30s later — indistinguishable from a missing host unless we
  /// catch it first.
  locationOff,

  /// The OS wouldn't do it: dialog dismissed, wrong passphrase, or the AP
  /// never turned up. The manual fallback takes over.
  declined,
}

/// Peer side: programmatically joins the host's network, reporting how it went
/// (anything but [HotspotJoinResult.joined] leaves the UI to offer a way out).
abstract interface class HotspotJoiner {
  Future<HotspotJoinResult> join(HotspotCredentials credentials);

  /// Turns the Wi-Fi radio back on for [HotspotJoinResult.wifiOff]. True when
  /// it is on by the time this returns; false when the user was handed a
  /// system toggle and the caller must wait for them to flip it.
  Future<bool> enableWifi();

  /// Opens the system Location screen for [HotspotJoinResult.locationOff].
  /// There is no app-facing switch for this one at any API level.
  Future<void> openLocationSettings();

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
