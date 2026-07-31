import '../entity/hotspot_credentials.dart';

/// Health of the hotspot link underneath a live session.
enum HotspotLinkState {
  /// No hotspot link to keep — plain Wi-Fi, Bluetooth, or nothing adopted yet.
  idle,

  /// On the link and holding.
  up,

  /// The link went away and we are trying to get it back.
  recovering,

  /// The link went away and cannot be recovered from here — a host whose AP
  /// came back under a new name, which the peer has no way to learn.
  lost,
}

/// Holds the hotspot link open for as long as the session runs.
///
/// [WifiHotspotCubit] can only watch the link while the pairing screen is on
/// screen; it is disposed the moment the channel opens, taking its `onLost`
/// subscription with it. So the one moment the link matters most — mid-call —
/// was the one moment nobody was listening, and a joiner pulled off the
/// hotspot went quiet in one direction with nothing noticing or retrying.
///
/// Being pulled off is not an edge case. A local-only hotspot has no internet,
/// and some Android builds simply will not stay on such a network: they
/// evaluate it, find nothing, and put the phone back on its saved Wi-Fi. The
/// app has to expect that and climb back on.
abstract interface class HotspotLinkKeeper {
  /// Link health, for a UI that wants to say something about it.
  Stream<HotspotLinkState> get states;

  /// Current health, for a listener that arrives after the fact.
  HotspotLinkState get state;

  /// Takes ownership of an established link. [credentials] are what a rejoin
  /// needs; the side this device is playing comes from the session role store.
  void adopt(HotspotCredentials credentials);

  /// Stops watching and abandons any recovery in flight. Does NOT tear the
  /// link down — leaving the channel and dropping the AP are separate
  /// decisions, and the AP outlives this by design.
  Future<void> release();

  /// Final teardown, on DI reset. [release] is what ends a session; this ends
  /// the object.
  void dispose();
}
