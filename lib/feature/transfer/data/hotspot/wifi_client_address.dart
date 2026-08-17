import 'dart:io';

import 'package:flutter/services.dart';
import 'package:tark/feature/transfer/domain/service/host_subnet_filter.dart';

/// This device's IPv4 address as a Wi-Fi **client**, when it has one.
///
/// The transport needs it to answer one question while hosting: of the private
/// addresses this phone holds, which one belongs to a network we merely joined
/// rather than to the access point we are serving? See [HostSubnetFilter] for
/// why that distinction decides whether two phones in the same room can hear
/// each other.
///
/// Deliberately a bare platform read rather than a repository method: it is
/// asked from the socket layer's own routing decision, has no state, and must
/// answer null — never throw, never block — everywhere the question doesn't
/// apply.
abstract final class WifiClientAddress {
  static const _channel = MethodChannel('tark/hotspot');

  /// Null off Android, when Wi-Fi is off, when not associated, or on any
  /// failure. Every one of those means the same thing to the caller: there is
  /// no client network to tell apart from ours.
  static Future<String?> current() async {
    if (!Platform.isAndroid) return null;
    try {
      return await _channel.invokeMethod<String>('clientIpv4');
    } on PlatformException {
      return null;
    } on MissingPluginException {
      return null;
    }
  }
}
