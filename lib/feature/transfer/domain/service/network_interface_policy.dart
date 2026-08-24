class NetworkInterfaceCandidate {
  const NetworkInterfaceCandidate({
    required this.name,
    required this.isLoopback,
    required this.isLinkLocal,
    required this.isVpnLike,
  });

  final String name;
  final bool isLoopback;
  final bool isLinkLocal;
  final bool isVpnLike;
}

/// Filters Dart-visible interfaces using Android's selected interface when the
/// native metadata is available. If metadata is unavailable, it falls back to
/// the old broad behavior minus interfaces that are never valid for local room
/// discovery (loopback/link-local/tunnel).
class NetworkInterfacePolicy {
  const NetworkInterfacePolicy();

  Iterable<NetworkInterfaceCandidate> select({
    required Iterable<NetworkInterfaceCandidate> candidates,
    String? selectedInterfaceName,
    bool selectedNetworkIsVpn = false,
  }) {
    final safe = candidates.where(
      (candidate) =>
          !candidate.isLoopback &&
          !candidate.isLinkLocal &&
          !candidate.isVpnLike,
    );

    final selected = selectedInterfaceName?.trim();
    if (selected == null || selected.isEmpty || selectedNetworkIsVpn) {
      return safe;
    }

    final exact = safe.where((candidate) => candidate.name == selected);
    if (exact.isNotEmpty) return exact;

    // Native metadata can momentarily lead Dart's NetworkInterface.list()
    // during a route transition. Falling back is safer than returning an empty
    // address set; generation checks make results from the old route stale.
    return safe;
  }
}
