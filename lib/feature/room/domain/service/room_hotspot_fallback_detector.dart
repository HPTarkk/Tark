/// Tells, from the routes a peer's signed proofs arrive on, when a call that
/// was on a hotspot is now going over some other network instead.
///
/// A call survives its access point dropping: both phones' Wi-Fi rejoins the
/// house router and the sockets carry on there. Nothing breaks, so nothing
/// noticed (2026-10-15: forty seconds on a Galaxy S8's hotspot, then the rest
/// of the call over the router, no move ever tried again). The proofs keep
/// arriving the whole time, and the network they arrive over is the one
/// thing that says where the call really is.
final class RoomHotspotFallbackDetector {
  RoomHotspotFallbackDetector({this.confirmations = 2})
    : assert(confirmations > 0);

  /// Proofs in a row from another network before it counts. One can be a
  /// straggler from the old socket.
  final int confirmations;

  String? _hotspotRoute;
  int _offHotspot = 0;

  /// The network the peer was proven on over the hotspot, once known.
  String? get hotspotRoute => _hotspotRoute;

  /// Forgets the hotspot's route: the call left the hotspot on purpose, or a
  /// planned hand-over is about to change it. The next proof is the new
  /// normal.
  void reset() {
    _hotspotRoute = null;
    _offHotspot = 0;
  }

  /// Takes [route] as the hotspot's when none is known yet.
  void seed(String? route) {
    if (route == null || route.isEmpty) return;
    _hotspotRoute ??= route;
  }

  /// Takes one proof's route; true once the call is plainly elsewhere.
  bool observe(String? route) {
    if (route == null || route.isEmpty) return false;
    final known = _hotspotRoute;
    if (known == null) {
      _hotspotRoute = route;
      return false;
    }
    if (sameNetwork(route, known)) {
      _offHotspot = 0;
      return false;
    }
    _offHotspot++;
    return _offHotspot >= confirmations;
  }

  /// Whether two routes are on the same network: the same /24 for IPv4
  /// addresses, otherwise the same route.
  static bool sameNetwork(String a, String b) {
    String? network(String address) {
      final parts = address.split('.');
      if (parts.length != 4) return null;
      for (final part in parts) {
        final value = int.tryParse(part);
        if (value == null || value < 0 || value > 255) return null;
      }
      return parts.take(3).join('.');
    }

    final x = network(a);
    final y = network(b);
    return x != null && y != null ? x == y : a == b;
  }
}
