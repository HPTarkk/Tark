import 'dart:math';

/// Which conversation a packet belongs to, when more than one is sharing a
/// network.
///
/// The gap this closes is the one P0 §1 deferred here on purpose. A session
/// epoch tells one sender's joins apart, and a device id tells senders apart —
/// neither can say that two groups of people on the same café Wi-Fi are having
/// two different conversations. Until now the app had no id for a channel at
/// all: "the channel" meant "the subnet", so everything on that LAN heard
/// everything else by construction. This is the channel finally having a name
/// of its own.
///
/// ## Why 24 bits, and why hex
///
/// It is read aloud and typed in as often as it is scanned: six uppercase hex
/// characters (`A83F21`) survive being shouted through a helmet and fit a
/// glance at a screen on a handlebar. 24 bits puts a collision between two
/// groups in earshot of each other far below the odds of anything else in this
/// app going wrong, which is the only comparison that matters — this separates
/// channels, it does not secure them.
///
/// **It is not a secret and must never be treated as one.** Anyone who can
/// hear the traffic can read the id straight off it, and anyone who wants in
/// can simply set theirs to match. Confidentiality is a different feature with
/// a different mechanism, and calling this one privacy would be the kind of
/// claim that stops people taking the real limits seriously.
///
/// ## Why zero means open rather than invalid
///
/// [open] is the value every build before this one effectively sends, every
/// point-to-point transport has no use for, and every zero-setup Wi-Fi session
/// starts on. Making it a legal value — "I have not asked to be separated from
/// anyone" — is what lets the whole feature ship without a migration: see
/// [ChannelGate] for the admission rule that falls out of it.
extension type const ChannelId(int value) {
  /// No channel stated. Talks to everyone, and everyone talks to it.
  static const open = ChannelId(0);

  /// Values above this cannot be written as six hex characters, so they could
  /// never be read back off a screen. The wire field is a uint32 for alignment
  /// with the epoch beside it; the extra byte is deliberately unused rather
  /// than silently truncated on display.
  static const maxValue = 0xFFFFFF;

  bool get isOpen => value == open.value;

  /// A fresh channel, never [open].
  ///
  /// Drawn from [Random.secure] where the platform has one. Not because the id
  /// is a secret — it is not, see above — but because a predictable generator
  /// makes two phones started at the same moment on the same build far more
  /// likely to collide than the bit width suggests, and collision is the one
  /// failure this value type exists to avoid.
  static ChannelId generate([Random? random]) {
    final rng = random ?? _secureOrFallback();
    // 1..maxValue: zero is reserved, and rerolling it would be a loop with a
    // one-in-sixteen-million branch nobody could ever test.
    return ChannelId(1 + rng.nextInt(maxValue));
  }

  static Random _secureOrFallback() {
    try {
      return Random.secure();
    } catch (_) {
      // Some platforms have no secure source. A worse random id is still an
      // id; refusing to make one would take the whole feature down.
      return Random();
    }
  }

  /// Six uppercase hex characters, or null when [open] — there is no code to
  /// show for a channel nobody named, and rendering `000000` would invite
  /// someone to type it in.
  String? get code =>
      isOpen ? null : value.toRadixString(16).toUpperCase().padLeft(6, '0');

  /// Parses a code a user typed or a scanner read.
  ///
  /// Deliberately forgiving about presentation and strict about content:
  /// case, surrounding whitespace and a `TARK-`/`TARK ` prefix are all things
  /// a person might reasonably produce from reading a screen, while anything
  /// that is not six hex digits is a wrong code rather than a wrong format —
  /// and joining the wrong channel silently is worse than being told to look
  /// again.
  static ChannelId? parse(String raw) {
    var text = raw.trim().toUpperCase();
    for (final prefix in const ['TARK-', 'TARK ', 'TARK:']) {
      if (text.startsWith(prefix)) {
        text = text.substring(prefix.length).trim();
        break;
      }
    }
    if (text.length != 6) return null;
    final parsed = int.tryParse(text, radix: 16);
    if (parsed == null || parsed <= 0 || parsed > maxValue) return null;
    return ChannelId(parsed);
  }

  /// Reads the wire field. Anything outside the representable range — a
  /// corrupted datagram, or a future format reusing the spare byte — reads as
  /// [open] rather than as a channel, so it can never quietly exclude a peer.
  static ChannelId fromWire(int raw) =>
      (raw <= 0 || raw > maxValue) ? open : ChannelId(raw);
}
