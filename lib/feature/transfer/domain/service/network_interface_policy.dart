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
/// safe local interfaces while excluding loopback/link-local/tunnel routes.
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
    return safe;
  }
}
