import 'dart:typed_data';

import '../../domain/entity/control_packet.dart';
import '../../domain/entity/transport_capability_advertisement.dart';
import 'media_receiver_feedback_wire.dart';
import 'transport_capability_advertisement_wire.dart';
import 'waki_packet_codec.dart';

/// Mixed-version-safe carrier for Room transport capability evidence.
///
/// Capability is appended to the existing ping/pong control tail. The legacy
/// v3 header and first 16 control-body bytes stay untouched. If #41 receiver
/// feedback is present, capability follows its fixed v1 record; otherwise it
/// starts immediately after the legacy body. Older builds already ignore bytes
/// after the control fields, while newer builds fail closed on absent,
/// truncated, unknown-version, or malformed capability evidence.
///
/// This codec only transports non-secret capability evidence. Attribution to a
/// durable RoomMemberId remains the responsibility of the verified
/// RoomTransportCapabilityObserver boundary.
final class TransportCapabilityControlCodec {
  const TransportCapabilityControlCodec(this.base);

  final WakiPacketCodec base;

  Uint8List encodePing({
    required int token,
    required int lastTxSeq,
    required int lastRxSeq,
    required int audioRxPackets,
    TransportCapabilityAdvertisement? capability,
  }) => appendCapability(
    base.encodePing(
      token: token,
      lastTxSeq: lastTxSeq,
      lastRxSeq: lastRxSeq,
      audioRxPackets: audioRxPackets,
    ),
    capability,
  );

  Uint8List encodePong({
    required int token,
    required int lastTxSeq,
    required int lastRxSeq,
    required int audioRxPackets,
    TransportCapabilityAdvertisement? capability,
  }) => appendCapability(
    base.encodePong(
      token: token,
      lastTxSeq: lastTxSeq,
      lastRxSeq: lastRxSeq,
      audioRxPackets: audioRxPackets,
    ),
    capability,
  );

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
        carrierPeerKey: fallbackSenderId,
      );
    }
    var capabilityOffset = legacyEnd;
    if (MediaReceiverFeedbackWire.decode(bytes, legacyEnd) != null) {
      capabilityOffset += MediaReceiverFeedbackWire.encodedLength;
    }

    return DecodedTransportCapabilityControl(
      packet: packet,
      capability: TransportCapabilityAdvertisementWire.decode(
        bytes,
        capabilityOffset,
      ),
      carrierPeerKey: fallbackSenderId,
    );
  }

  /// Appends capability to an already encoded control packet.
  ///
  /// Public primarily so an existing heartbeat adapter that already appended
  /// #41 receiver feedback can add this record without re-encoding the packet.
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

  /// Returns the byte immediately after the original 16-byte control body.
  ///
  /// Production encoders currently use an empty sender name, but the shared v3
  /// header decoder intentionally accepts a non-empty one. Capability parsing
  /// must therefore honor the encoded name length instead of assuming the body
  /// always starts four bytes after the epoch. Otherwise a valid control packet
  /// from a compatible peer can make arbitrary name bytes look like a trailer.
  /// Malformed/truncated headers fail closed to no capability evidence.
  static int? _legacyControlLength(Uint8List bytes) {
    if (bytes.length < 2) return null;
    final idLength = bytes[1];
    var offset = 2 + idLength;

    // Control always carries a uint32 epoch, then a uint32 sender-name length.
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
    required this.carrierPeerKey,
  });

  final ControlPacket packet;
  final TransportCapabilityAdvertisement? capability;

  /// Route identity observed by the local carrier while receiving this packet.
  ///
  /// This is intentionally distinct from [ControlPacket.senderId], which is
  /// payload-controlled. Room capability/failover attribution must preserve the
  /// carrier-observed route until cryptographic proof binds it to a member.
  final String carrierPeerKey;
}
