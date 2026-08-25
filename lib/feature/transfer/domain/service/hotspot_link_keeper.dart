import '../entity/hotspot_credentials.dart';

/// Health of the hotspot link underneath a live session.
enum HotspotLinkState {
  /// No hotspot link to keep — plain Wi-Fi, Bluetooth, or nothing adopted yet.
  idle,

  /// On the link and holding. After a host re-creates an AP, this is emitted
  /// only once bidirectional peer evidence confirms the new attachment works.
  up,

  /// The link went away and we are trying to get it back.
  recovering,

  /// Recovery exhausted its bounded attempts and needs a user decision.
  lost,
}

/// Holds the hotspot link open for as long as the session runs.
///
/// The logical Room is not owned here. This object owns only the temporary
/// hotspot attachment underneath it; losing or replacing that attachment must
/// never imply that the user left the Room.
abstract interface class HotspotLinkKeeper {
  /// Link health, for a UI that wants to say something about it.
  Stream<HotspotLinkState> get states;

  /// Current health, for a listener that arrives after the fact.
  HotspotLinkState get state;

  /// Current credentials for the temporary hotspot attachment, if one exists.
  /// Room identity must never be derived from these values.
  HotspotCredentials? get credentials;

  /// Emits whenever Android creates fresh hotspot credentials during recovery.
  /// #39's in-room invite/rejoin surface consumes this rather than caching the
  /// credentials that happened to exist when the Room was first entered.
  Stream<HotspotCredentials> get credentialChanges;

  /// Takes ownership of an established link. [credentials] are what a rejoin
  /// needs; the side this device is playing comes from the session role store.
  void adopt(HotspotCredentials credentials);

  /// Stops watching and abandons any recovery in flight. Does NOT tear the
  /// link down — leaving the Room and dropping the AP are separate decisions.
  Future<void> release();

  /// Restarts bounded recovery after it gave up. No-op in every other state.
  void retryNow();

  /// Final teardown, on DI reset. [release] is what ends a session; this ends
  /// the object.
  void dispose();
}
