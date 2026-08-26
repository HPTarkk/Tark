import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:tark/core/identity/session_epoch.dart';
import 'package:tark/feature/audio/domain/media_adaptation_controller.dart';
import 'package:tark/feature/transfer/data/codec/media_feedback_heartbeat_runtime.dart';
import 'package:tark/feature/transfer/data/codec/waki_packet_codec.dart';
import 'package:tark/feature/transfer/domain/entity/control_packet.dart';
import 'package:tark/feature/transfer/domain/entity/media_receiver_feedback.dart';

void main() {
  const feedback = MediaReceiverFeedback(
    queuedMs: 130,
    underruns: 1,
    outputStarvations: 2,
    trims: 3,
    overflowDrops: 4,
    staleDrops: 5,
    duplicateDrops: 6,
    resyncs: 7,
    concealedMs: 80,
  );

  WakiPacketCodec codec(String id) =>
      WakiPacketCodec(id, SessionEpoch(initialValue: 17));

  test('ping advertises the current local receiver window additively', () {
    final runtime = MediaFeedbackHeartbeatRuntime(
      baseCodec: codec('sender-a'),
      localFeedback: () => feedback,
    );

    final bytes = runtime.encodePing(
      token: 44,
      lastTxSeq: 12,
      lastRxSeq: 11,
      audioRxPackets: 10,
    );
    final decoded = MediaFeedbackHeartbeatRuntime(
      baseCodec: codec('receiver-b'),
      localFeedback: () => null,
    ).decodeControl(bytes, 'fallback');

    expect(decoded, isA<PingPacket>());
    final ping = decoded! as PingPacket;
    expect(ping.token, 44);
    expect(ping.lastTxSeq, 12);
    expect(ping.lastRxSeq, 11);
    expect(ping.audioRxPackets, 10);
    expect(ping.mediaReceiverFeedback?.queuedMs, 130);
    expect(ping.mediaReceiverFeedback?.staleDrops, 5);
  });

  test('null local feedback preserves legacy heartbeat bytes exactly', () {
    final base = codec('sender-a');
    final runtime = MediaFeedbackHeartbeatRuntime(
      baseCodec: base,
      localFeedback: () => null,
    );

    final legacy = base.encodePong(
      token: 9,
      lastTxSeq: 8,
      lastRxSeq: 7,
      audioRxPackets: 6,
    );
    final wrapped = runtime.encodePong(
      token: 9,
      lastTxSeq: 8,
      lastRxSeq: 7,
      audioRxPackets: 6,
    );

    expect(wrapped, orderedEquals(legacy));
  });

  test('only matched pong feedback is admitted to adaptation', () {
    final runtime = MediaFeedbackHeartbeatRuntime(
      baseCodec: codec('sender-a'),
      localFeedback: () => null,
    );
    final now = DateTime.utc(2026, 8, 26, 9);

    var decision = runtime.evaluate(
      peerIds: const ['peer-b'],
      now: now,
      elapsedMs: 1000,
    );
    expect(decision.tier, MediaAdaptationTier.unconfirmed);

    runtime.observeMatchedPong(
      const PongPacket(
        senderId: 'peer-b',
        sessionEpoch: 4,
        token: 1,
        mediaReceiverFeedback: feedback,
      ),
      now,
    );
    decision = runtime.evaluate(
      peerIds: const ['peer-b'],
      now: now,
      elapsedMs: 1000,
    );
    expect(decision.tier, MediaAdaptationTier.conservative);
  });

  test('mixed-version pong remains unconfirmed', () {
    final sender = codec('peer-old');
    final bytes = sender.encodePong(
      token: 3,
      lastTxSeq: 2,
      lastRxSeq: 1,
      audioRxPackets: 1,
    );
    final runtime = MediaFeedbackHeartbeatRuntime(
      baseCodec: codec('new-peer'),
      localFeedback: () => null,
    );
    final decoded = runtime.decodeControl(Uint8List.fromList(bytes), 'old');
    expect(decoded, isA<PongPacket>());
    expect(decoded!.mediaReceiverFeedback, isNull);

    final now = DateTime.utc(2026, 8, 26, 9);
    runtime.observeMatchedPong(decoded as PongPacket, now);
    final decision = runtime.evaluate(
      peerIds: const ['peer-old'],
      now: now,
      elapsedMs: 1000,
    );
    expect(decision.tier, MediaAdaptationTier.unconfirmed);
  });

  test('remove and reset discard session receiver evidence', () {
    final runtime = MediaFeedbackHeartbeatRuntime(
      baseCodec: codec('sender-a'),
      localFeedback: () => null,
    );
    final now = DateTime.utc(2026, 8, 26, 9);
    const pong = PongPacket(
      senderId: 'peer-b',
      sessionEpoch: 4,
      token: 1,
      mediaReceiverFeedback: feedback,
    );

    runtime.observeMatchedPong(pong, now);
    runtime.removePeer('peer-b');
    expect(
      runtime.evaluate(
        peerIds: const ['peer-b'],
        now: now,
        elapsedMs: 1000,
      ).tier,
      MediaAdaptationTier.unconfirmed,
    );

    runtime.observeMatchedPong(pong, now);
    runtime.reset();
    expect(
      runtime.evaluate(
        peerIds: const ['peer-b'],
        now: now,
        elapsedMs: 1000,
      ).tier,
      MediaAdaptationTier.unconfirmed,
    );
  });
}
