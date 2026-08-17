/// Keeps a hotspot host talking on its own access point and nowhere else.
///
/// ## The failure this exists for
///
/// A phone hosting a local-only hotspot while still connected to a Wi-Fi
/// network has **two** private IPv4 interfaces: the AP it is serving, and the
/// network it is a client on. The transport's discovery posture sprays every
/// private subnet it can see, which is right for a phone that doesn't yet know
/// where its peers are — and wrong for a host, which knows exactly where they
/// are, because it is the thing they connected to.
///
/// Left unfiltered, the host announces itself on the home network as well as
/// on its own AP. Two phones that are genuinely in the same room then end up
/// in what looks like two different rooms: the joiner is on the AP subnet and
/// can only be heard there, while the host's traffic goes out the interface
/// with the default route. Both screens show an empty channel, which is the
/// worst possible presentation — nothing is broken enough to report, and every
/// diagnostic on both phones reads healthy.
///
/// Observed in a field test: host on home Wi-Fi + hosting, joiner on the AP,
/// both entered the channel, neither ever saw the other.
///
/// ## Why this is safe
///
/// It only ever *removes* the subnet of a network we are a client on, and only
/// while this device is the host. A host has no reason to reach peers anywhere
/// but its own AP — anyone on the home network is not in this session, and if
/// they were, they would have had to join the hotspot to get here. The limited
/// broadcast `255.255.255.255` is deliberately left alone: it does not name a
/// subnet, it costs one datagram, and it is the fallback for every device whose
/// AP interface never appears in `NetworkInterface.list` at all.
abstract final class HostSubnetFilter {
  /// The /24 prefix of [ip], or null if it isn't a dotted-quad.
  static String? prefixOf(String? ip) {
    if (ip == null) return null;
    final parts = ip.split('.');
    if (parts.length != 4) return null;
    if (parts.any((p) => int.tryParse(p) == null)) return null;
    return '${parts[0]}.${parts[1]}.${parts[2]}';
  }

  /// Drops [clientIp]'s subnet from [subnets] when [isHost].
  ///
  /// Returns [subnets] unchanged in every other case — not hosting, no client
  /// address to exclude, or an exclusion that would leave nothing behind.
  ///
  /// That last guard matters more than it looks. On a single-radio phone the
  /// framework drops the Wi-Fi client connection when the AP comes up, and for
  /// a moment the *only* subnet we can see may still be the one we are about to
  /// exclude — a stale read racing the teardown. Filtering down to nothing
  /// there would leave the host unable to reach anybody at all, turning a
  /// transient into a dead session. Keeping everything is the safe direction:
  /// the worst case is the unfiltered behaviour we already shipped.
  static List<String> apply({
    required List<String> subnets,
    required String? clientIp,
    required bool isHost,
  }) {
    if (!isHost) return subnets;
    final exclude = prefixOf(clientIp);
    if (exclude == null) return subnets;
    final kept = subnets.where((s) => s != exclude).toList(growable: false);
    return kept.isEmpty ? subnets : kept;
  }
}
