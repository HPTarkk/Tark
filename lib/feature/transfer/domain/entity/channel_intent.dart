/// Which end of a pairing this device is: the one arranging it, or the one
/// arriving.
///
/// This is the axis the primary screen is now organised around, replacing
/// "which transport?". The difference matters: the transport is a fact about
/// the two phones and their surroundings, which the app can observe, while the
/// intent is a fact about the two people, which it cannot. Asking only the
/// second question and inferring the first is the whole of P2 §1 — see
/// `TransportAdvisor`, which is where the inference lives. (Named rather than
/// linked: the advisor imports this file, so a doc link back would have the
/// analyzer pull a cycle in behind it.)
///
/// It is deliberately *not* the same thing as `SessionRole`. A role is claimed
/// for the life of a session and decides who owns the network; an intent is a
/// tap on the landing page that may resolve to no role at all, which is
/// exactly what happens on a shared Wi-Fi where nobody hosts anything.
enum ChannelIntent {
  /// "I'll set this up." Whatever has to exist before anyone can talk — an
  /// access point, a Bluetooth server socket — this device brings up.
  create,

  /// "Someone else set it up." This device goes looking for it.
  join;

  String get key => switch (this) {
    ChannelIntent.create => 'create',
    ChannelIntent.join => 'join',
  };

  static ChannelIntent? fromKey(String? key) => switch (key) {
    'create' => ChannelIntent.create,
    'join' => ChannelIntent.join,
    _ => null,
  };
}
