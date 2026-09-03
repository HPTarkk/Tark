import 'dart:typed_data';

import '../../domain/entity/control_packet.dart';
import '../../domain/entity/transport_capability_advertisement.dart';
import 'carrier_handover_wire.dart';
import 'media_receiver_feedback_wire.dart';
import 'transport_capability_advertisement_wire.dart';
import 'transport_route_proof_wire.dart';
import 'waki_packet_codec.dart';

/// Mixed-version-safe carrier for Room transport capability evidence and an
/// optional opaque route proof.
///
/// The legacy v3 header and first 16 control-body bytes stay untouched. Existing
/// #41 receiver feedback remains first, then the fixed capability record when
/// present, then the self-framed carrier handover, then the self-framed route
/// proof. Older builds already ignore bytes after the control fields. Newer
/// builds fail closed on absent, truncated, unknown-version or malformed
/// trailers.
///
/// The route proof stays last because its decoder asserts it reaches the end of
/// the datagram; every trailer added from here on goes *before* it.
///
/// This codec never interprets the proof as Room identity. Attribution remains
/// behind the cryptographic Room proof boundary.
final class TransportCapabilityControlCodec {
  const TransportCapabilityControlCodec(this.base);

  final WakiPacketCodec base;

  Uint8List encodePing({
    required int token,
    required int lastTxSeq,
    required int lastRxSeq,
    required int audioRxPackets,
    TransportCapabilityAdvertisement? capability,
    String? carrierHandover,
  }) => appendCarrierHandover(
    appendCapability(
      base.encodePing(
        token: token,
        lastTxSeq: lastTxSeq,
        lastRxSeq: lastRxSeq,
        audioRxPackets: audioRxPackets,
      ),
      capability,
    ),
    carrierHandover,
  );

  Uint8List encodePong({
    required int token,
    required int lastTxSeq,
    required int lastRxSeq,
    required int audioRxPackets,
    TransportCapabilityAdvertisement? capability,
    String? routeProof,
    String? carrierHandover,
  }) {
    final withCapability = appendCapability(
      base.encodePong(
        token: token,
        lastTxSeq: lastTxSeq,
        lastRxSeq: lastRxSeq,
        audioRxPackets: audioRxPackets,
      ),
      capability,
    );
    // Handover before the route proof, never after: the proof's decoder
    // asserts it runs to the end of the datagram, so anything appended past it
    // makes a perfectly good proof unreadable.
    return appendRouteProof(
      appendCarrierHandover(withCapability, carrierHandover),
      routeProof,
    );
  }

  DecodedTransportCapabilityControl? decodeControl(
    Uint8List bytes,
    String fallbackSenderId,
  ) {
    final packet = base.decodeControl(bytes, fallbackSenderId);
    if (packet == null) return null;

    final legacyEnd = _legacyControlLength(bytes);
    if (legacyEnd == null) {
      return DecodedTransportCapabilityControl(
        packet: packet,
        capability: null,
        routeProof: null,
        carrierHandover: null,
        carrierPeerKey: fallbackSenderId,
      );
    }
    var trailerOffset = legacyEnd;
    if (MediaReceiverFeedbackWire.decode(bytes, legacyEnd) != null) {
      trailerOffset += MediaReceiverFeedbackWire.encodedLength;
    }

    final capability = TransportCapabilityAdvertisementWire.decode(
      bytes,
      trailerOffset,
    );
    if (capability != null) {
      trailerOffset += TransportCapabilityAdvertisementWire.encodedLength;
    }

    final carrierHandover = CarrierHandoverWire.decode(bytes, trailerOffset);
    trailerOffset += CarrierHandoverWire.encodedLengthAt(bytes, trailerOffset);

    return DecodedTransportCapabilityControl(
      packet: packet,
      capability: capability,
      routeProof: TransportRouteProofWire.decode(bytes, trailerOffset),
      carrierHandover: carrierHandover,
      carrierPeerKey: fallbackSenderId,
    );
  }

  static Uint8List appendCapability(
    Uint8List packet,
    TransportCapabilityAdvertisement? capability,
  ) {
    if (capability == null) return packet;
    final trailer = TransportCapabilityAdvertisementWire.encode(capability);
    final result = Uint8List(packet.length + trailer.length);
    result.setRange(0, packet.length, packet);
    result.setRange(packet.length, result.length, trailer);
    return result;
  }

  static Uint8List appendCarrierHandover(
    Uint8List packet,
    String? carrierHandover,
  ) {
    if (carrierHandover == null) return packet;
    final trailer = CarrierHandoverWire.encode(carrierHandover);
    final result = Uint8List(packet.length + trailer.length);
    result.setRange(0, packet.length, packet);
    result.setRange(packet.length, result.length, trailer);
    return result;
  }

  static Uint8List appendRouteProof(Uint8List packet, String? routeProof) {
    if (routeProof == null) return packet;
    final trailer = TransportRouteProofWire.encode(routeProof);
    final result = Uint8List(packet.length + trailer.length);
    result.setRange(0, packet.length, packet);
    result.setRange(packet.length, result.length, trailer);
    return result;
  }

  static int? _legacyControlLength(Uint8List bytes) {
    if (bytes.length < 2) return null;
    final idLength = bytes[1];
    var offset = 2 + idLength;
    if (bytes.length < offset + 8) return null;
    offset += 4;
    final nameLength = ByteData.sublistView(
      bytes,
    ).getUint32(offset, Endian.little);
    offset += 4;
    if (nameLength > bytes.length - offset) return null;
    offset += nameLength;
    const controlBodyLength = 16;
    if (bytes.length < offset + controlBodyLength) return null;
    return offset + controlBodyLength;
  }
}

final class DecodedTransportCapabilityControl {
  const DecodedTransportCapabilityControl({
    required this.packet,
    required this.capability,
    required this.routeProof,
    required this.carrierHandover,
    required this.carrierPeerKey,
  });

  final ControlPacket packet;
  final TransportCapabilityAdvertisement? capability;
  final String? routeProof;

  /// A signed instruction to move the Room onto a new network, still encoded.
  /// Verification belongs to the Room layer, which is the only place that
  /// holds the issuer key it has to chain to.
  final String? carrierHandover;

  final String carrierPeerKey;
}
