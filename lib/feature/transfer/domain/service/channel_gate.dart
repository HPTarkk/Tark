import '../../../../core/identity/channel_id.dart';

/// Decides whether a packet belongs to the conversation this device is having.
///
/// ## The rule, and why it is this one
///
/// A packet is admitted when the two channels match, **or when either side is
/// [ChannelId.open]**. Written out:
///
/// | mine | theirs | admitted | because |
/// | :--- | :--- | :--- | :--- |
/// | open | open | yes | nobody asked to be separated — today's behaviour |
/// | open | X | yes | we named no channel, so we may refuse nobody |
/// | X | open | yes | they never got a code; excluding them is not our call |
/// | X | X | yes | same channel |
/// | X | Y | **no** | two conversations, one network |
///
/// Only the last row drops anything, and it is the only row that describes the
/// bug: two groups on one café Wi-Fi hearing each other because the transport's
/// idea of "the channel" is "the subnet".
///
/// ## Why open is permissive rather than strict
///
/// The tempting rule is "a device in channel X hears only channel X", and it
/// breaks the app on the day it ships. Every build before this one stamps no
/// id at all, so a strict gate would split every mixed-version session — the
/// exact failure the wire format's forward compatibility exists to prevent,
/// and the same reason [SessionEpochGate] refuses to grade a packet that
/// states no epoch. Zero-setup Wi-Fi would break too: two phones that have
/// both just tapped through have no code between them and must still hear each
/// other, or the app grows a mandatory pairing step for its simplest case.
///
/// So separation is something both ends opt into, and it is worth being
/// precise about what that buys. Two groups are kept apart as soon as **one
/// person in each** has started a channel, because starting one is what
/// "create" does. Someone who joined without a code hears both — which is not
/// a failure of the gate: they have not said which conversation they are in,
/// and silently picking one for them would be a guess with no evidence behind
/// it.
///
/// ## Not a security boundary
///
/// See [ChannelId]. The id travels in clear on every packet and anyone can set
/// theirs to match. This class separates channels; it does not protect them.
///
/// Pure bookkeeping — the caller does the logging and the counting — so it is
/// testable without a socket, the same way [SessionEpochGate] is.
class ChannelGate {
  const ChannelGate(this._mine);

  final ChannelId _mine;

  /// Whether a packet stamped [theirs] is part of our conversation.
  bool admits(ChannelId theirs) =>
      _mine.isOpen || theirs.isOpen || _mine.value == theirs.value;

  /// Whether [theirs] is a channel we are deliberately excluding, as opposed
  /// to merely not sharing.
  ///
  /// The difference is what makes a drop worth reporting: a phone that hears a
  /// neighbouring channel and correctly ignores it has *found another group*,
  /// and that is the one piece of evidence a user needs when they ask why
  /// their friend cannot hear them. Silence with a busy network behind it is
  /// the hardest failure in this app to diagnose from a screenshot.
  bool excludes(ChannelId theirs) => !admits(theirs);
}
