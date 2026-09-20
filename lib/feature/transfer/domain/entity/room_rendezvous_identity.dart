import 'dart:convert';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

/// Privacy-safe BLE selector derived from a Room invitation id.
///
/// This is NOT authentication. It only lets the joiner choose the right nearby
/// Tark advertiser before the signed Room challenge/receipt protocol runs over
/// RFCOMM. Only this short one-way digest goes over BLE/native channels.
final class RoomRendezvousIdentity {
  const RoomRendezvousIdentity({
    required this.serviceData,
    required this.correlation,
  });

  static const int protocolVersion = 1;
  static const int serviceDataLength = 8;

  final Uint8List serviceData;
  final String correlation;

  static Future<RoomRendezvousIdentity> derive(String invitationId) async {
    final clean = invitationId.trim().toLowerCase();
    if (!RegExp(r'^[0-9a-f]{8,64}$').hasMatch(clean)) {
      throw const FormatException('invalid proximity rendezvous token');
    }
    final digest = await Sha256().hash(utf8.encode(clean));
    final bytes = digest.bytes;
    final data = Uint8List(serviceDataLength)
      ..[0] = protocolVersion
      ..setRange(1, serviceDataLength, bytes);
    final correlation = bytes
        .take(4)
        .map((value) => value.toRadixString(16).padLeft(2, '0'))
        .join();
    return RoomRendezvousIdentity(
      serviceData: data,
      correlation: correlation,
    );
  }
}
