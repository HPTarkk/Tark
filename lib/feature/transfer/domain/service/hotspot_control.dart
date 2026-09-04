import '../entity/hotspot_credentials.dart';

/// Whether leaving Wi-Fi on is likely to cost this host its hotspot.
///
/// On a phone whose chipset can't run a client connection and an access point
/// at once, the framework tears our AP down as soon as the Wi-Fi side
/// reconnects — a saved network drifting back into range mid-ride ends the
/// channel, and it arrives as an ordinary OS teardown with nothing marking it
/// as this cause. The device knows the answer in advance
/// (`isStaApConcurrencySupported`), so the warning can come before the failure
/// instead of after it.
///
/// **Advisory only.** Nothing in this app can turn Wi-Fi off:
/// `setWifiEnabled` has been a no-op returning false for non-system apps since
/// Android 10, with no replacement. The switch is the user's, so the whole job
/// is asking for it at the right moment and making it one tap.
class HotspotWifiAdvice {
  /// The Wi-Fi radio is on right now.
  final bool wifiEnabled;

  /// This device can hold a client connection and an AP simultaneously.
  final bool concurrent;

  /// The system offers the floating Wi-Fi panel (Android 10+), which toggles
  /// the radio without taking the user off our screen. Where false, the button
  /// still works but navigates to full settings.
  final bool canPanel;

  const HotspotWifiAdvice({
    required this.wifiEnabled,
    required this.concurrent,
    required this.canPanel,
  });

  /// Nothing to say — the safe default everywhere the question can't be asked
  /// (iOS, desktop, a channel that isn't there).
  static const none = HotspotWifiAdvice(
    wifiEnabled: false,
    concurrent: true,
    canPanel: false,
  );

  /// Worth telling the user about: the radio is on, and this device can't hold
  /// both. Either alone is fine — Wi-Fi off is already the good state, and a
  /// concurrent chipset copes with it being on.
  bool get shouldSuggestWifiOff => wifiEnabled && !concurrent;
}

/// Android host side of the hotspot bridge: brings up a local-only AP and
/// reports OS-initiated teardowns so the UI can re-host.
abstract interface class HotspotHost {
  /// Starts the hotspot and returns its credentials. Throws on failure (or
  /// off Android); callers surface that as an error card.
  Future<HotspotCredentials> start();

  Future<void> stop();

  /// Whether an access point raised by this app is on the air right now.
  ///
  /// The one link state no network API can be asked about: a local-only
  /// hotspot is not a network this device is *on*, so `ConnectivityManager`
  /// reports the phone as having no Wi-Fi at the exact moment it is holding
  /// the Wi-Fi that everyone else in the room is using. The reservation lives
  /// and dies with this process, which is what makes an in-process answer the
  /// accurate one rather than a cached guess.
  bool get isHosting;

  /// Fires when the OS tears the hotspot down on its own (radio conflict,
  /// Doze, an STA reconnect stealing the single radio) — never for an
  /// app-initiated [stop].
  Stream<void> get onStopped;

  /// Opens the system screen where the user can fix a [start] failure —
  /// Location for `location_off`, tethering for `tethering_on`. No-op where
  /// the screen doesn't exist.
  Future<void> openFixSettings(String errorCode);

  /// Reads whether this device's Wi-Fi state puts the hotspot at risk. Cheap
  /// enough to re-ask whenever the app comes back to the foreground, which is
  /// how the note learns the user has acted on it.
  Future<HotspotWifiAdvice> wifiAdvice();

  /// Opens the Wi-Fi toggle — the floating panel where the platform has one,
  /// so the host keeps the QR on screen for the other phone. Returns whether
  /// it stayed in-place.
  Future<bool> openWifiPanel();
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

  /// Fires when the joined network goes away for good (the host's AP died or
  /// moved out of range), so the peer can re-scan instead of sitting on a dead
  /// link. A drop the platform recovers from on its own reaches [onRebound]
  /// instead and never surfaces here.
  Stream<void> get onLost;

  /// Fires when the OS dropped the joined network and put us back on it — the
  /// screen-off case, where an app-scoped connection is released and a
  /// system-owned one replaces it seconds later.
  ///
  /// The link is up again, so this is not a failure. It still needs acting on:
  /// the process is pinned to a NEW network handle, and every socket built on
  /// the old one is now sending into a route that no longer exists.
  Stream<void> get onRebound;
}
