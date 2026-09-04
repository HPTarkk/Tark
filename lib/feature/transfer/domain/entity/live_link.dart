import 'transfer_mode.dart';

/// What is carrying voice right now.
///
/// Every other transport question in this app is about what *could* work —
/// `TransportAdvisor` picks a route from what the device is capable of,
/// `ConnectionHealth` grades a session that already exists. This one sits in
/// the gap between them: a link has been established, and nothing has been
/// asked of it yet. It is the only question worth asking before a channel
/// opens, because a channel opened over nothing looks exactly like a channel
/// opened over a link that has gone quiet.
enum LiveLink {
  /// No network, no access point of our own, no Bluetooth peer.
  none,

  /// Associated with a Wi-Fi network.
  ///
  /// Deliberately one value rather than two. A router's network and a host's
  /// hotspot are the same fact from this side — an association with an access
  /// point somebody else is holding open — and there is no signal available
  /// here that tells them apart. Pretending otherwise would put a guess in the
  /// one place that exists to stop guessing.
  wifi,

  /// This device *is* the access point.
  hotspotHost,

  /// A Bluetooth link is up.
  bluetooth;

  bool get isUp => this != LiveLink.none;

  /// Whether having this link is itself evidence that somebody else is on the
  /// other end of it.
  ///
  /// Only Bluetooth, and the asymmetry is the whole point. A Bluetooth link
  /// *is* a peer — there is no such thing as being connected over Bluetooth to
  /// nobody. Every other answer here is about this phone alone: an access
  /// point with nobody on it is indistinguishable from a busy one, and being
  /// associated with a Wi-Fi network says nothing about whether the other
  /// phone is on the same one. Nothing available before traffic closes that
  /// gap either — a matching SSID would not, because client isolation on a
  /// café or guest network is exactly the case that breaks this app while
  /// every name and address still matches.
  ///
  /// So the app does not guess. It says what it can see, is explicit that the
  /// rest is unknown until somebody is heard, and keeps the way onto a shared
  /// network one tap away on both screens where the question comes up.
  bool get provesPeer => this == LiveLink.bluetooth;

  /// Whether anybody *arranged* this link, as opposed to the app finding a
  /// network that happened to already be there.
  ///
  /// The weaker question underneath [provesPeer], and the more useful one
  /// before a channel opens. Bluetooth and an access point of our own are both
  /// deliberate acts a minute old — somebody paired, or somebody raised an AP,
  /// *for this*. Being associated with a Wi-Fi network is not: the app opens
  /// at home, on the home Wi-Fi, and the person holding it is as likely to be
  /// about to walk out the door as to stay. `TransportAdvisor` has reasoned
  /// this way since it was written — its hotspot rung leads precisely because
  /// `hasWifi` cannot see the other phone — and the pre-ride lobby was the one
  /// screen left that read a network it found as a network the room is on.
  ///
  /// **The mode is the discriminator, and it is the only one there is.** A
  /// joiner that came through the bridge is associated with an access point
  /// and is indistinguishable from a phone on a router from this side; what
  /// tells them apart is that the bridge *wrote down* what it established (see
  /// `WifiHotspotCubit._recordCarrier`). So [TransferMode.hotspot] on a Wi-Fi
  /// link means these two phones agreed on this network, and
  /// [TransferMode.wifi] means the app found it already up.
  bool arranged(TransferMode mode) => switch (this) {
    LiveLink.none => false,
    // Neither can happen by walking into a building.
    LiveLink.bluetooth || LiveLink.hotspotHost => true,
    // Guest counts for the same reason the bridge does: the guest page only
    // reaches a channel once a browser has attached, so the far end is a peer
    // this device handed a link to rather than one it is hoping to find.
    LiveLink.wifi => mode == TransferMode.hotspot || mode == TransferMode.guest,
  };

  /// Whether a session set to [mode] can run over this link.
  ///
  /// The three IP transports — Wi-Fi, the hotspot bridge and the browser guest
  /// — are all carried by an association, because all three are sockets on a
  /// local network and the link cannot tell them apart. Only the hotspot host
  /// is narrower, and only in one direction: a device holding an access point
  /// up is not on a shared network, so plain Wi-Fi is not what it is doing.
  bool carries(TransferMode mode) => switch (this) {
    LiveLink.none => false,
    LiveLink.wifi => mode != TransferMode.bluetooth,
    // Not [TransferMode.wifi]: the Wi-Fi repository runs underneath both, but
    // the Room's attachment record would otherwise write a bridge this phone
    // is hosting down as an ordinary network that was always there. Guest is
    // included — a browser can perfectly well be on the access point we
    // raised.
    LiveLink.hotspotHost =>
      mode == TransferMode.hotspot || mode == TransferMode.guest,
    LiveLink.bluetooth => mode == TransferMode.bluetooth,
  };

  /// The transport to run over this link, given what the app is set to now.
  ///
  /// A mode that already fits is left exactly alone, and that is the whole
  /// reason this is not simply "derive the mode from the link". Wi-Fi, the
  /// hotspot bridge and the browser guest are one association wearing three
  /// names, and only the mode remembers which — re-deriving it from a link
  /// that cannot tell a router from an access point would quietly relabel a
  /// joined hotspot as a network that was always there, and would drop a
  /// browser guest onto a transport with no browser on it.
  TransferMode modeFor(TransferMode current) {
    if (carries(current)) return current;
    return switch (this) {
      LiveLink.none => current,
      LiveLink.wifi => TransferMode.wifi,
      LiveLink.hotspotHost => TransferMode.hotspot,
      LiveLink.bluetooth => TransferMode.bluetooth,
    };
  }
}

/// Every link that is up at one instant, before anything has been decided
/// about which of them a session should use.
///
/// Three bools rather than a resolved [LiveLink] because the resolution needs
/// the current transport, and the thing that reads the radios has no business
/// knowing about it. Keeping them apart is what makes the decision testable
/// without a device — the same split `TransportAdvisor` uses.
class LiveLinkSnapshot {
  const LiveLinkSnapshot({
    required this.wifi,
    required this.hostingHotspot,
    required this.bluetooth,
  });

  /// Associated with a Wi-Fi network — a router's, or one a host raised.
  final bool wifi;

  /// This device is holding an access point up.
  final bool hostingHotspot;

  /// A Bluetooth peer is connected.
  final bool bluetooth;

  /// Nothing is up. Also what a probe reports when it could not read the
  /// radios at all: no evidence of a link is not evidence of one.
  static const none = LiveLinkSnapshot(
    wifi: false,
    hostingHotspot: false,
    bluetooth: false,
  );

  bool get isUp => wifi || hostingHotspot || bluetooth;

  /// The link a session set to [current] should run over.
  ///
  /// A link that already carries the current transport wins outright, so a
  /// transport the user chose is never silently traded for another that
  /// happens to also be up — a phone paired over Bluetooth in a house with
  /// Wi-Fi must not be moved onto the Wi-Fi behind the user's back.
  ///
  /// Only when none of them fits does the order below decide, and it is the
  /// order of how deliberate each link is: raising an access point is
  /// something a person did on purpose a minute ago, being on a Wi-Fi network
  /// is something that may have happened by walking into a building, and
  /// Bluetooth comes last because it is the narrowest of the three rather
  /// than because it is the least likely.
  LiveLink resolve(TransferMode current) {
    final up = <LiveLink>[
      if (hostingHotspot) LiveLink.hotspotHost,
      if (wifi) LiveLink.wifi,
      if (bluetooth) LiveLink.bluetooth,
    ];
    for (final link in up) {
      if (link.carries(current)) return link;
    }
    return up.isEmpty ? LiveLink.none : up.first;
  }
}
