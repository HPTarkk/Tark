import '../entity/guest_link_state.dart';

/// Host-side control surface for inviting a web guest — the QR handshake
/// that replaces a signaling server. Separate from [TransferRepository] the
/// same way [BluetoothTransport] is: establishing the link is its own flow,
/// moving packets afterwards is the repository's job.
abstract interface class GuestLinkController {
  Stream<GuestLinkState> get linkState;

  /// Creates a fresh WebRTC offer (LAN candidates included) and returns it
  /// as a compact QR-safe payload. Any previous link is torn down.
  Future<String> createInvite();

  /// Applies the guest's scanned reply code. The link state moves to
  /// [GuestLinkState.connected] once the data channel opens.
  Future<void> acceptAnswer(String payload);

  /// Tears the link down without disposing the repository.
  void endSession();
}
