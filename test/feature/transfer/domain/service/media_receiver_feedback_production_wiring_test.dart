import 'package:flutter_test/flutter_test.dart';
import 'package:tark/core/identity/session_epoch.dart';
import 'package:tark/feature/audio/domain/media_adaptation_controller.dart';
import 'package:tark/feature/audio/domain/media_receive_buffer.dart';
import 'package:tark/feature/transfer/data/codec/waki_packet_codec.dart';
import 'package:tark/feature/transfer/domain/entity/control_packet.dart';
import 'package:tark/feature/transfer/domain/entity/media_receiver_feedback.dart';
import 'package:tark/feature/transfer/domain/service/media_opus_tuner.dart';
import 'package:tark/feature/transfer/domain/service/media_quality_controller.dart';
import 'package:tark/feature/transfer/domain/service/media_receiver_feedback_session.dart';
import 'package:tark/feature/transfer/domain/service/opus_tuner.dart';
import 'package:tark/feature/transfer/domain/service/peer_ping_tracker.dart';

void main() {
  final feedbackSession = MediaReceiverFeedbackSession.shared;

  setUp(feedbackSession.reset);
  tearDown(feedbackSession.reset);

  test('live codec advertises the active media receive health window', () {
    final buffer = MediaReceiveBuffer(
      sampleRate: 1000,
      targetBufferMs: 20,
      maxQueueMs: 100,
    );
    addTearDown(buffer.dispose);
    buffer.feed(List<double>.filled(20, 0.1), 1, 'media-sender');

    final sender = WakiPacketCodec('peer-b', SessionEpoch.startingAt(2));
    final receiver = WakiPacketCodec('peer-a', SessionEpoch.startingAt(3));
    addTearDown(sender.release);
    addTearDown(receiver.release);

    final bytes = sender.encodePong(
      token: 7,
      lastTxSeq: 3,
      lastRxSeq: 2,
      audioRxPackets: 1,
    );
    final decoded = receiver.decodeControl(bytes, '10.0.0.2');

    expect(decoded, isA<PongPacket>());
    expect(decoded!.mediaReceiverFeedback, isNotNull);
    expect(decoded.mediaReceiverFeedback!.queuedMs, 20);
  });

  test('unmatched pong cannot confirm staged receiver feedback', () {
    final tracker = PeerPingTracker(receiverFeedback: feedbackSession);
    final now = DateTime.utc(2026, 8, 26, 12);
    tracker.sent('peer-route', 10, now);
    feedbackSession.stagePong(
      address: 'peer-route',
      peerId: 'peer-b',
      token: 99,
      feedback: _cleanFeedback,
    );

    expect(tracker.pong('peer-route', 99, now), isNull);
    final decision = feedbackSession.evaluate(now, 1000);
    expect(decision.tier, MediaAdaptationTier.unconfirmed);
  });

  test('matched pong admits severe distress and suspends media first', () {
    final tracker = PeerPingTracker(receiverFeedback: feedbackSession);
    final now = DateTime.utc(2026, 8, 26, 12);
    tracker.sent('peer-route', 10, now);
    feedbackSession.stagePong(
      address: 'peer-route',
      peerId: 'peer-b',
      token: 10,
      feedback: const MediaReceiverFeedback(
        queuedMs: 390,
        underruns: 3,
        outputStarvations: 2,
        trims: 2,
        overflowDrops: 1,
        staleDrops: 4,
        duplicateDrops: 0,
        resyncs: 1,
        concealedMs: 40,
      ),
    );

    expect(tracker.pong('peer-route', 10, now), Duration.zero);
    feedbackSession.evaluate(now, 1000);

    final quality = MediaQualityController(receiverFeedback: feedbackSession);
    expect(quality.shouldSend, isFalse);
  });

  test('unconfirmed receiver evidence caps a clean sender at 48 kbps', () {
    feedbackSession.reset();
    const tuner = MediaOpusTuner();

    final tuning = tuner.tune(const AudioLinkConditions());

    expect(tuning.bitrate, 48000);
    expect(feedbackSession.decision.tier, MediaAdaptationTier.unconfirmed);
  });

  test('matched clean evidence upgrades deterministically with dwell', () {
    final tracker = PeerPingTracker(receiverFeedback: feedbackSession);
    var now = DateTime.utc(2026, 8, 26, 12);

    for (var window = 0; window < 12; window++) {
      final token = 100 + window;
      tracker.sent('peer-route', token, now);
      feedbackSession.stagePong(
        address: 'peer-route',
        peerId: 'peer-b',
        token: token,
        feedback: _cleanFeedback,
      );
      expect(tracker.pong('peer-route', token, now), Duration.zero);
      feedbackSession.evaluate(now, 1000);
      now = now.add(const Duration(seconds: 1));
    }

    expect(
      feedbackSession.decision.tier,
      anyOf(MediaAdaptationTier.balanced, MediaAdaptationTier.high),
    );
    expect(feedbackSession.decision.targetBitrateKbps, greaterThan(48));
  });
}

const _cleanFeedback = MediaReceiverFeedback(
  queuedMs: 120,
  underruns: 0,
  outputStarvations: 0,
  trims: 0,
  overflowDrops: 0,
  staleDrops: 0,
  duplicateDrops: 0,
  resyncs: 0,
  concealedMs: 0,
);
