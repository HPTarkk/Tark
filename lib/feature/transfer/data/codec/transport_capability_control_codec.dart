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

  /// Current ping/pong uses a v3 header with an empty sender name:
  /// type + idLength + id + epoch + nameLength + 16-byte control body.
  static int _legacyControlLength(Uint8List bytes) {
    if (bytes.length < 2) return bytes.length;
    return 1 + 1 + bytes[1] + 4 + 4 + 16;
  }
}

final class DecodedTransportCapabilityControl {
  const DecodedTransportCapabilityControl({
    required this.packet,
    required this.capability,
  });

  final ControlPacket packet;
  final TransportCapabilityAdvertisement? capability;
}
