import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:tark/core/identity/session_epoch.dart';
import 'package:tark/feature/transfer/data/codec/media_feedback_control_codec.dart';
import 'package:tark/feature/transfer/data/codec/media_receiver_feedback_wire.dart';
import 'package:tark/feature/transfer/data/codec/waki_packet_codec.dart';
import 'package:tark/feature/transfer/domain/entity/control_packet.dart';
import 'package:tark/feature/transfer/domain/entity/media_receiver_feedback.dart';

void main() {
  late WakiPacketCodec base;
  late MediaFeedbackControlCodec codec;

  setUp(() {
    base = WakiPacketCodec('abc123abc123', SessionEpoch.startingAt(9));
    codec = MediaFeedbackControlCodec(base);
  });

  tearDown(() => base.release());

  const feedback = MediaReceiverFeedback(
    queuedMs: 180,
    underruns: 2,
    outputStarvations: 3,
    trims: 4,
    overflowDrops: 5,
    staleDrops: 6,
    duplicateDrops: 7,
    resyncs: 8,
    concealedMs: 90,
  );

  void expectFeedback(MediaReceiverFeedback? actual) {
    expect(actual, isNotNull);
    expect(actual!.queuedMs, feedback.queuedMs);
    expect(actual.underruns, feedback.underruns);
    expect(actual.outputStarvations, feedback.outputStarvations);
    expect(actual.trims, feedback.trims);
    expect(actual.overflowDrops, feedback.overflowDrops);
    expect(actual.staleDrops, feedback.staleDrops);
    expect(actual.duplicateDrops, feedback.duplicateDrops);
    expect(actual.resyncs, feedback.resyncs);
    expect(actual.concealedMs, feedback.concealedMs);
  }

  test(
    'legacy control packet remains byte-for-byte unchanged without feedback',
    () {
      final legacy = base.encodePing(
        token: 12,
        lastTxSeq: 30,
        lastRxSeq: 20,
        audioRxPackets: 18,
      );
      final adapted = codec.encodePing(
        token: 12,
        lastTxSeq: 30,
        lastRxSeq: 20,
        audioRxPackets: 18,
      );

      expect(adapted, legacy);
      final decoded = codec.decodeControl(adapted, 'fallback');
      expect(decoded, isA<PingPacket>());
      expect(decoded!.mediaReceiverFeedback, isNull);
    },
  );

  test('ping carries receiver feedback as an additive trailer', () {
    final encoded = codec.encodePing(
      token: 77,
      lastTxSeq: 101,
      lastRxSeq: 99,
      audioRxPackets: 95,
      mediaReceiverFeedback: feedback,
    );

    final decoded = codec.decodeControl(encoded, 'fallback') as PingPacket;
    expect(decoded.token, 77);
    expect(decoded.lastTxSeq, 101);
    expect(decoded.lastRxSeq, 99);
    expect(decoded.audioRxPackets, 95);
    expectFeedback(decoded.mediaReceiverFeedback);
  });

  test('pong carries receiver feedback as an additive trailer', () {
    final encoded = codec.encodePong(
      token: 88,
      lastTxSeq: 201,
      lastRxSeq: 199,
      audioRxPackets: 150,
      mediaReceiverFeedback: feedback,
    );

    final decoded = codec.decodeControl(encoded, 'fallback') as PongPacket;
    expect(decoded.token, 88);
    expectFeedback(decoded.mediaReceiverFeedback);
  });

  test('truncated receiver trailer fails closed to unconfirmed', () {
    final encoded = codec.encodePing(
      token: 1,
      lastTxSeq: 2,
      lastRxSeq: 3,
      audioRxPackets: 4,
      mediaReceiverFeedback: feedback,
    );
    final truncated = Uint8List.sublistView(encoded, 0, encoded.length - 3);

    final decoded = codec.decodeControl(truncated, 'fallback');
    expect(decoded, isA<PingPacket>());
    expect(decoded!.mediaReceiverFeedback, isNull);
  });

  test('unknown receiver trailer version fails closed to unconfirmed', () {
    final encoded = codec.encodePing(
      token: 1,
      lastTxSeq: 2,
      lastRxSeq: 3,
      audioRxPackets: 4,
      mediaReceiverFeedback: feedback,
    );
    final legacyLength =
        encoded.length - MediaReceiverFeedbackWire.encodedLength;
    encoded[legacyLength] = MediaReceiverFeedbackWire.version + 1;

    final decoded = codec.decodeControl(encoded, 'fallback');
    expect(decoded, isA<PingPacket>());
    expect(decoded!.mediaReceiverFeedback, isNull);
  });
}
