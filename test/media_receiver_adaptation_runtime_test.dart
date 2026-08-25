// dart format off
import 'package:flutter_test/flutter_test.dart';
import 'package:tark/feature/audio/domain/media_adaptation_controller.dart';
import 'package:tark/feature/transfer/domain/entity/media_receiver_feedback.dart';
import 'package:tark/feature/transfer/domain/service/media_receiver_adaptation_runtime.dart';
import 'package:tark/feature/transfer/domain/service/media_receiver_feedback_store.dart';

void main() {
  const clean = MediaReceiverFeedback(
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

  const severe = MediaReceiverFeedback(
    queuedMs: 420,
    underruns: 2,
    outputStarvations: 2,
    trims: 0,
    overflowDrops: 1,
    staleDrops: 3,
    duplicateDrops: 0,
    resyncs: 1,
    concealedMs: 80,
  );
// dart format on

// dart format off
  test('missing feedback stays unconfirmed', () {
    final runtime = MediaReceiverAdaptationRuntime.standard();
    final now = DateTime.utc(2026, 8, 25, 20);
    final decision = runtime.evaluate(
      peerIds: const ['peer-a'],
      now: now,
      elapsedMs: 2000,
    );

    expect(decision.tier, MediaAdaptationTier.unconfirmed);
    expect(decision.targetBitrateKbps, 48);
    expect(decision.targetChannels, 1);
  });

  test('clean feedback starts conservative', () {
    final runtime = MediaReceiverAdaptationRuntime.standard();
    final now = DateTime.utc(2026, 8, 25, 20);
    runtime.observePeer('peer-a', clean, now);
    final decision = runtime.evaluate(
      peerIds: const ['peer-a'],
      now: now,
      elapsedMs: 2000,
    );

    expect(decision.tier, MediaAdaptationTier.conservative);
    expect(decision.reason, MediaAdaptationReason.confirmedClean);
    expect(decision.targetBitrateKbps, 48);
  });

  test('severe receiver suspends media', () {
    final runtime = MediaReceiverAdaptationRuntime.standard();
    final now = DateTime.utc(2026, 8, 25, 20);
    runtime.observePeer('peer-a', clean, now);
    runtime.observePeer('peer-b', severe, now);
    final decision = runtime.evaluate(
      peerIds: const ['peer-a', 'peer-b'],
      now: now,
      elapsedMs: 1000,
    );

    expect(decision.tier, MediaAdaptationTier.suspended);
    expect(decision.reason, MediaAdaptationReason.severeReceiverDistress);
    expect(decision.shouldTransmit, isFalse);
  });
// dart format on

  test('stale feedback becomes unconfirmed', () {
    final runtime = MediaReceiverAdaptationRuntime(
      store: MediaReceiverFeedbackStore(
        staleAfter: const Duration(seconds: 8),
      ),
      controller: MediaAdaptationController(),
    );
    final now = DateTime.utc(2026, 8, 25, 20);
    runtime.observePeer('peer-a', clean, now);
    final current = runtime.evaluate(
      peerIds: const ['peer-a'],
      now: now,
      elapsedMs: 1000,
    );
    final stale = runtime.evaluate(
      peerIds: const ['peer-a'],
      now: now.add(const Duration(seconds: 9)),
      elapsedMs: 9000,
    );

    expect(current.tier, MediaAdaptationTier.conservative);
    expect(stale.tier, MediaAdaptationTier.unconfirmed);
    expect(stale.reason, MediaAdaptationReason.feedbackUnconfirmed);
  });

  test('remove and reset discard old health', () {
    final runtime = MediaReceiverAdaptationRuntime.standard();
    final now = DateTime.utc(2026, 8, 25, 20);
    runtime.observePeer('peer-a', clean, now);
    runtime.removePeer('peer-a');
    final afterRemoval = runtime.evaluate(
      peerIds: const ['peer-a'],
      now: now,
      elapsedMs: 1000,
    );

    runtime.observePeer('peer-a', clean, now);
    final restored = runtime.evaluate(
      peerIds: const ['peer-a'],
      now: now,
      elapsedMs: 1000,
    );
    runtime.reset();
    final afterReset = runtime.evaluate(
      peerIds: const ['peer-a'],
      now: now,
      elapsedMs: 1000,
    );

    expect(afterRemoval.tier, MediaAdaptationTier.unconfirmed);
    expect(restored.tier, MediaAdaptationTier.conservative);
    expect(afterReset.tier, MediaAdaptationTier.unconfirmed);
  });

  test('voice impairment suspends media', () {
    final runtime = MediaReceiverAdaptationRuntime.standard();
    final now = DateTime.utc(2026, 8, 25, 20);
    final decision = runtime.evaluate(
      peerIds: const ['peer-a'],
      now: now,
      elapsedMs: 1000,
      voiceImpaired: true,
    );

    expect(decision.tier, MediaAdaptationTier.suspended);
    expect(decision.reason, MediaAdaptationReason.voiceProtection);
  });
}
