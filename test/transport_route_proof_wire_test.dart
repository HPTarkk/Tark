import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:tark/core/identity/session_epoch.dart';
import 'package:tark/feature/transfer/data/codec/transport_capability_control_codec.dart';
import 'package:tark/feature/transfer/data/codec/transport_route_proof_wire.dart';
import 'package:tark/feature/transfer/data/codec/waki_packet_codec.dart';

void main() {
  test('route proof round trips as a bounded additive Pong trailer', () {
    final codec = TransportCapabilityControlCodec(
      WakiPacketCodec('abcdef123456', SessionEpoch.startingAt(9)),
    );
    final bytes = codec.encodePong(
      token: 17,
      lastTxSeq: 18,
      lastRxSeq: 19,
      audioRxPackets: 20,
      routeProof: 'signed-room-proof',
    );

    final decoded = codec.decodeControl(bytes, '10.0.0.8');
    expect(decoded, isNotNull);
    expect(decoded!.packet.token, 17);
    expect(decoded.routeProof, 'signed-room-proof');
    expect(decoded.carrierPeerKey, '10.0.0.8');
  });

  test('legacy control decoder still accepts a Pong with proof tail', () {
    final base = WakiPacketCodec('abcdef123456', SessionEpoch.startingAt(9));
    final codec = TransportCapabilityControlCodec(base);
    final bytes = codec.encodePong(
      token: 31,
      lastTxSeq: 32,
      lastRxSeq: 33,
      audioRxPackets: 34,
      routeProof: 'opaque-proof',
    );

    final legacy = base.decodeControl(bytes, 'legacy-peer');
    expect(legacy, isNotNull);
    expect(legacy!.token, 31);
  });

  test('malformed, oversized and trailing route proof fail closed', () {
    expect(TransportRouteProofWire.decode(Uint8List(3), 0), isNull);
    expect(
      () => TransportRouteProofWire.encode(
        'x' * (TransportRouteProofWire.maxProofBytes + 1),
      ),
      throwsFormatException,
    );

    final valid = TransportRouteProofWire.encode('proof');
    final withTrailing = Uint8List(valid.length + 1)
      ..setRange(0, valid.length, valid)
      ..[valid.length] = 0xff;
    expect(TransportRouteProofWire.decode(withTrailing, 0), isNull);

    final unknownVersion = Uint8List.fromList(valid);
    unknownVersion[1] = 99;
    expect(TransportRouteProofWire.decode(unknownVersion, 0), isNull);
  });
}
