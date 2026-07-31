/// What part a device plays in the link the channel runs over.
///
/// Announced by every device in its own presence packets rather than guessed
/// by the receiver: a phone that joined someone's hotspot can see two other
/// phones on the subnet and has no way to tell which of them brought the AP
/// up. The sender always knows, so the sender says.
enum SessionRole {
  /// Brought the link up and holds it open — the Bluetooth host, the phone
  /// running the hotspot, the app hosting a browser guest.
  host,

  /// Came in over a link someone else is holding open.
  joiner,

  /// No hierarchy to report: everyone met on a network that was already
  /// there (plain Wi-Fi through a router).
  peer,

  /// Nothing was announced — a peer on a build older than roles, or a
  /// transport that hasn't settled on a side yet.
  unknown;

  /// Wire value carried in presence packets. Fixed once shipped: an older
  /// build's bytes are read back by this table.
  int get wireByte => switch (this) {
    SessionRole.unknown => 0,
    SessionRole.host => 1,
    SessionRole.joiner => 2,
    SessionRole.peer => 3,
  };

  /// Anything unrecognised decodes to [unknown] — a future build may announce
  /// a role this one has never heard of, and that must not drop the packet.
  static SessionRole fromWire(int byte) => switch (byte) {
    1 => SessionRole.host,
    2 => SessionRole.joiner,
    3 => SessionRole.peer,
    _ => SessionRole.unknown,
  };
}
