import 'dart:typed_data';

import '../../domain/entity/control_packet.dart';
import '../../domain/entity/media_receiver_feedback.dart';
import 'media_receiver_feedback_wire.dart';
import 'waki_packet_codec.dart';

/// Additive control-codec adapter for Shared Music receiver feedback.
///
/// The legacy ping/pong body stays byte-for-byte unchanged. Receiver health is
/// appended as a versioned trailer, so older builds ignore it while newer
/// builds can consume real receiver evidence. Missing, truncated or unknown
/// trailers remain null/unconfirmed.
final class MediaFeedbackControlCodec {
  const MediaFeedbackControlCodec(this.base);

  final WakiPacketCodec base;

  Uint8List encodePing({
    required int token,
    required int lastTxSeq,
    required int lastRxSeq,
    required int audioRxPackets,
    MediaReceiverFeedback? mediaReceiverFeedback,
  }) => _append(
    base.encodePing(
      token: token,
      lastTxSeq: lastTxSeq,
      lastRxSeq: lastRxSeq,
      audioRxPackets: audioRxPackets,
    ),
    mediaReceiverFeedback,
  );

  Uint8List encodePong({
    required int token,
    required int lastTxSeq,
    required int lastRxSeq,
    required int audioRxPackets,
    MediaReceiverFeedback? mediaReceiverFeedback,
  }) => _append(
    base.encodePong(
      token: token,
      lastTxSeq: lastTxSeq,
      lastRxSeq: lastRxSeq,
      audioRxPackets: audioRxPackets,
    ),
    mediaReceiverFeedback,
  );

  ControlPacket? decodeControl(Uint8List bytes, String fallbackSenderId) {
    final packet = base.decodeControl(bytes, fallbackSenderId);
    if (packet == null) return null;
    final feedback = MediaReceiverFeedbackWire.decode(
      bytes,
      _legacyControlLength(bytes),
    );
    return switch (packet) {
      PingPacket() => PingPacket(
        senderId: packet.senderId,
        sessionEpoch: packet.sessionEpoch,
        token: packet.token,
        lastTxSeq: packet.lastTxSeq,
        lastRxSeq: packet.lastRxSeq,
        audioRxPackets: packet.audioRxPackets,
        mediaReceiverFeedback: feedback,
      ),
      PongPacket() => PongPacket(
        senderId: packet.senderId,
        sessionEpoch: packet.sessionEpoch,
        token: packet.token,
        lastTxSeq: packet.lastTxSeq,
        lastRxSeq: packet.lastRxSeq,
        audioRxPackets: packet.audioRxPackets,
        mediaReceiverFeedback: feedback,
      ),
    };
  }

  static Uint8List _append(Uint8List packet, MediaReceiverFeedback? feedback) {
    if (feedback == null) return packet;
    final trailer = MediaReceiverFeedbackWire.encode(feedback);
    final result = Uint8List(packet.length + trailer.length);
    result.setRange(0, packet.length, packet);
    result.setRange(packet.length, result.length, trailer);
    return result;
  }

  /// Current ping/pong messages always use the v3 header with an empty sender
  /// name: type + idLength + id + epoch + nameLength + 16-byte control body.
  /// Keeping this calculation here avoids teaching the session packet codec
  /// about an optional feature trailer and preserves its mixed-version shape.
  static int _legacyControlLength(Uint8List bytes) {
    if (bytes.length < 2) return bytes.length;
    return 1 + 1 + bytes[1] + 4 + 4 + 16;
  }
}
