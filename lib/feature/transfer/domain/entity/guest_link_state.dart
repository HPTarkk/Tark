/// Lifecycle of a WebRTC guest link (both the native host side and the web
/// guest side move through the same phases).
enum GuestLinkState {
  idle,

  /// Building the local offer/answer (gathering LAN candidates).
  preparing,

  /// Host: invite QR is showing, waiting for the guest's reply code.
  /// Guest: reply QR is showing, waiting for the host to scan it.
  awaitingPeer,

  /// Data channel open — audio can flow.
  connected,

  failed,
}
