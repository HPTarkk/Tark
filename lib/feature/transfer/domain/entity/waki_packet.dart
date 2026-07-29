import 'package:equatable/equatable.dart';

sealed class WakiPacket extends Equatable {
  final String senderId;
  final String senderName;

  const WakiPacket({required this.senderId, required this.senderName});

  @override
  List<Object?> get props => [senderId, senderName];
}

final class PresencePacket extends WakiPacket {
  final bool isTalking;

  const PresencePacket({
    required super.senderId,
    required super.senderName,
    required this.isTalking,
  });

  @override
  List<Object?> get props => [...super.props, isTalking];
}

final class AudioPacket extends WakiPacket {
  final List<double> samples;

  /// Monotonically increasing per-sender counter used by the jitter buffer
  /// to detect lost/out-of-order UDP packets and conceal the gaps.
  final int seq;

  /// Optional v2 metadata. All timestamps are monotonic microseconds from
  /// the sender process unless documented otherwise; they are suitable for
  /// per-device stage latency, not absolute cross-device latency.
  final AudioPacketMetadata? metadata;

  const AudioPacket({
    required super.senderId,
    required super.senderName,
    required this.samples,
    required this.seq,
    this.metadata,
  });

  @override
  List<Object?> get props => [...super.props, samples, seq, metadata];
}

final class AudioPacketMetadata extends Equatable {
  const AudioPacketMetadata({
    required this.protocolVersion,
    required this.sequenceNumber,
    this.captureTimestampUs,
    this.encodeCompleteTimestampUs,
    this.sendTimestampUs,
    this.senderMonotonicTimestampUs,
    this.codecIdentifier,
    this.frameDurationMs,
    this.sessionId,
    this.streamId,
  });

  final int protocolVersion;
  final int sequenceNumber;
  final int? captureTimestampUs;
  final int? encodeCompleteTimestampUs;
  final int? sendTimestampUs;
  final int? senderMonotonicTimestampUs;
  final String? codecIdentifier;
  final int? frameDurationMs;
  final String? sessionId;
  final String? streamId;

  int? get encodeLatencyUs =>
      captureTimestampUs == null || encodeCompleteTimestampUs == null
      ? null
      : encodeCompleteTimestampUs! - captureTimestampUs!;

  int? get localQueueLatencyUs =>
      encodeCompleteTimestampUs == null || sendTimestampUs == null
      ? null
      : sendTimestampUs! - encodeCompleteTimestampUs!;

  @override
  List<Object?> get props => [
    protocolVersion,
    sequenceNumber,
    captureTimestampUs,
    encodeCompleteTimestampUs,
    sendTimestampUs,
    senderMonotonicTimestampUs,
    codecIdentifier,
    frameDurationMs,
    sessionId,
    streamId,
  ];
}
