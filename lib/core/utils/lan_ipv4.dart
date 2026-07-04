import 'dart:io';

/// Helpers for picking the right IPv4 identity on multi-interface devices.
///
/// Phones commonly hold several IPv4 addresses at once: the WiFi LAN address
/// (en0 on iOS, wlan0 on Android), the cellular carrier address (pdp_ip0 —
/// often a public IP), and on IPv6-only carriers the CLAT translation stub
/// 192.0.0.x. Only the private LAN address is meaningful to this app, and
/// interface enumeration order is arbitrary, so "first non-loopback address"
/// regularly picks the wrong one — on iOS it showed the cellular IP while
/// the device sat on a perfectly good WiFi network.
abstract final class LanIpv4 {
  /// RFC1918 private ranges: 10/8, 172.16/12, 192.168/16.
  static bool isPrivate(String ip) {
    final parts = ip.split('.').map(int.tryParse).toList();
    if (parts.length != 4 || parts.any((o) => o == null)) return false;
    final a = parts[0]!, b = parts[1]!;
    return a == 10 ||
        (a == 172 && b >= 16 && b <= 31) ||
        (a == 192 && b == 168);
  }

  /// Snapshot of all non-loopback IPv4 addresses with their interface names.
  static Future<List<({String name, String address})>> addresses() async {
    final result = <({String name, String address})>[];
    final interfaces =
        await NetworkInterface.list(type: InternetAddressType.IPv4);
    for (final iface in interfaces) {
      for (final addr in iface.addresses) {
        if (!addr.isLoopback) {
          result.add((name: iface.name, address: addr.address));
        }
      }
    }
    return result;
  }

  /// The address peers on the local network can actually reach us at:
  /// prefers private (RFC1918) addresses, and among those prefers the
  /// WiFi/hotspot interface (en0/bridge on iOS, wlan*/ap*/swlan* on
  /// Android). Returns null when no usable address exists.
  static String? bestLocalAddress(
      List<({String name, String address})> addrs) {
    final private = addrs.where((e) => isPrivate(e.address)).toList();
    if (private.isNotEmpty) {
      for (final e in private) {
        final n = e.name.toLowerCase();
        if (n.startsWith('en') ||
            n.startsWith('wlan') ||
            n.startsWith('bridge') ||
            n.startsWith('ap') ||
            n.startsWith('swlan')) {
          return e.address;
        }
      }
      return private.first.address;
    }
    // No private address — fall back to anything that isn't the CLAT stub
    // (192.0.0.x is never reachable by peers), e.g. a public-IP campus WiFi.
    for (final e in addrs) {
      if (!e.address.startsWith('192.0.0.')) return e.address;
    }
    return null;
  }
}
