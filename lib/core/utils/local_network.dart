import 'dart:io';

import 'logger.dart';

/// This device's local IPv4 address, the one fact both a channel action
/// (`LandingCubit`) and Preflight's transport-readiness check (#33) need —
/// "is there a usable local network path" is the same question either way,
/// so it has one answer.
abstract final class LocalNetwork {
  static Future<String?> ipv4Address() async {
    try {
      final interfaces = await NetworkInterface.list(
        type: InternetAddressType.IPv4,
      );
      for (final iface in interfaces) {
        for (final addr in iface.addresses) {
          if (!addr.isLoopback) return addr.address;
        }
      }
    } catch (e) {
      Logger.log('Could not get local IP: $e');
    }
    return null;
  }
}
