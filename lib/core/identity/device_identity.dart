import 'dart:math';

import 'package:injectable/injectable.dart';

/// Who this device is inside a channel, independent of the network path any
/// given packet happened to take.
///
/// Wi-Fi identity used to be the UDP source address, which is not one value per
/// device. A phone sitting on the hotspot subnet *and* another interface sends
/// each packet twice — the limited broadcast leaves by the default route, the
/// directed one by the AP interface — so the same device arrived under two
/// source IPs. Every peer then showed up twice in the roster, and worse, its
/// audio was split across two jitter-buffer streams each seeing every other
/// [AudioPacket.seq] and treating the gaps as loss.
///
/// Generated per process rather than persisted: identity only has to hold for
/// the life of a channel, and an app that restarted genuinely is a new
/// participant — its previous entry ages out of the roster on its own.
@lazySingleton
class DeviceIdentity {
  /// 12 hex characters. Far beyond collision range for the handful of phones
  /// in one channel, and small enough that carrying it on every audio packet
  /// costs nothing that matters.
  final String id;

  DeviceIdentity() : id = _generate();

  /// Fixed id, for tests that need to predict what lands on the wire.
  const DeviceIdentity.withId(this.id);

  static String _generate() {
    final random = Random.secure();
    final buffer = StringBuffer();
    for (var i = 0; i < _idLength; i++) {
      buffer.write(random.nextInt(16).toRadixString(16));
    }
    return buffer.toString();
  }

  static const _idLength = 12;
}
