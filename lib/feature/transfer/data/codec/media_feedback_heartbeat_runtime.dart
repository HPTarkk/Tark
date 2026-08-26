import 'dart:typed_data';

import '../../../audio/domain/media_adaptation_controller.dart';
import '../../domain/entity/control_packet.dart';
import '../../domain/entity/media_receiver_feedback.dart';
import '../../domain/service/media_receiver_adaptation_runtime.dart';
import 'media_feedback_control_codec.dart';
import 'waki_packet_codec.dart';

/// Session-scoped bridge for carrying Shared Music receiver health on the
/// existing ping/pong heartbeat and turning confirmed remote feedback into a
/// sender adaptation decision.
///
/// This class deliberately owns no timer or socket. Wi-Fi already has a
/// one-second heartbeat; production only needs to call [encodePing]/
/// [encodePong], [decodeControl], [observeMatchedPong], and [evaluate] from
/// that existing cadence. Keeping those mechanics here prevents receiver
/// adaptation from expanding `WifiTransferRepositoryImpl` into another policy
/// owner.
///
/// Missing local feedback writes the legacy packet byte-for-byte. Missing or
/// mixed-version remote feedback remains unconfirmed in
/// [MediaReceiverAdaptationRuntime] rather than being fabricated as healthy.
final class MediaFeedbackHeartbeatRuntime {
  MediaFeedbackHeartbeatRuntime({
    required WakiPacketCodec baseCodec,
    required this.localFeedback,
    MediaReceiverAdaptationRuntime? adaptation,
  }) : _codec = MediaFeedbackControlCodec(baseCodec),
       _adaptation = adaptation ?? MediaReceiverAdaptationRuntime.standard();

  final MediaFeedbackControlCodec _codec;
  final MediaReceiverAdaptationRuntime _adaptation;

  /// Supplies the most recent bounded receiver-health window. A null result
  /// means this device has no receiver evidence to advertise yet.
  final MediaReceiverFeedback? Function() localFeedback;

  Uint8List encodePing({
    required int token,
    required int lastTxSeq,
    required int lastRxSeq,
    required int audioRxPackets,
  }) => _codec.encodePing(
    token: token,
    lastTxSeq: lastTxSeq,
    lastRxSeq: lastRxSeq,
    audioRxPackets: audioRxPackets,
    mediaReceiverFeedback: localFeedback(),
  );

  Uint8List encodePong({
    required int token,
    required int lastTxSeq,
    required int lastRxSeq,
    required int audioRxPackets,
  }) => _codec.encodePong(
    token: token,
    lastTxSeq: lastTxSeq,
    lastRxSeq: lastRxSeq,
    audioRxPackets: audioRxPackets,
    mediaReceiverFeedback: localFeedback(),
  );

  ControlPacket? decodeControl(Uint8List bytes, String fallbackSenderId) =>
      _codec.decodeControl(bytes, fallbackSenderId);

  /// Records receiver evidence only after the caller has matched the pong to
  /// an outstanding heartbeat. An unsolicited/stale pong must not confirm a
  /// peer or influence media quality.
  void observeMatchedPong(PongPacket pong, DateTime now) {
    final feedback = pong.mediaReceiverFeedback;
    if (feedback == null) return;
    _adaptation.observePeer(pong.senderId, feedback, now);
  }

  MediaAdaptationDecision evaluate({
    required Iterable<String> peerIds,
    required DateTime now,
    required int elapsedMs,
    bool voiceImpaired = false,
  }) => _adaptation.evaluate(
    peerIds: peerIds,
    now: now,
    elapsedMs: elapsedMs,
    voiceImpaired: voiceImpaired,
  );

  void removePeer(String peerId) => _adaptation.removePeer(peerId);

  void reset() => _adaptation.reset();
}
