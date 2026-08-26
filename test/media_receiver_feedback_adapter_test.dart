import 'package:flutter_test/flutter_test.dart';
import 'package:tark/feature/audio/domain/media_adaptation_controller.dart';
import 'package:tark/feature/audio/domain/media_receive_buffer.dart';
import 'package:tark/feature/audio/domain/media_receiver_feedback_adapter.dart';
import 'package:tark/feature/transfer/domain/entity/media_receiver_feedback.dart';

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

  test('missing feedback remains unconfirmed instead of clean', () {
    final window = MediaReceiverFeedbackAdapter.toWindow(null);

    expect(window.bidirectionalConfirmed, isFalse);
    expect(window.distressed, isFalse);

    final decision = MediaAdaptationController().observe(
      receivers: [window],
      elapsedMs: 2000,
    );
    expect(decision.tier, MediaAdaptationTier.unconfirmed);
    expect(decision.targetBitrateKbps, 48);
    expect(decision.targetChannels, 1);
  });

  test('confirmed transport feedback preserves every health signal', () {
    const feedback = MediaReceiverFeedback(
      queuedMs: 390,
      underruns: 2,
      outputStarvations: 3,
      trims: 4,
      overflowDrops: 5,
      staleDrops: 6,
      duplicateDrops: 7,
      resyncs: 8,
      concealedMs: 9,
    );

    final window = MediaReceiverFeedbackAdapter.toWindow(feedback);

    expect(window.bidirectionalConfirmed, isTrue);
    expect(window.health.queuedMs, 390);
    expect(window.health.underruns, 2);
    expect(window.health.outputStarvations, 3);
    expect(window.health.trims, 4);
    expect(window.health.overflowDrops, 5);
    expect(window.health.staleDrops, 6);
    expect(window.health.duplicateDrops, 7);
    expect(window.health.resyncs, 8);
    expect(window.health.concealedMs, 9);
    expect(window.severeDistress, isTrue);
  });

  test('local receiver health maps losslessly to transport feedback', () {
    const health = MediaReceiveHealth(
      queuedMs: 137,
      underruns: 2,
      outputStarvations: 3,
      trims: 4,
      overflowDrops: 5,
      staleDrops: 6,
      duplicateDrops: 7,
      resyncs: 8,
      concealedMs: 39,
    );

    final feedback = MediaReceiverFeedbackAdapter.fromHealth(health);

    expect(feedback.queuedMs, health.queuedMs);
    expect(feedback.underruns, health.underruns);
    expect(feedback.outputStarvations, health.outputStarvations);
    expect(feedback.trims, health.trims);
    expect(feedback.overflowDrops, health.overflowDrops);
    expect(feedback.staleDrops, health.staleDrops);
    expect(feedback.duplicateDrops, health.duplicateDrops);
    expect(feedback.resyncs, health.resyncs);
    expect(feedback.concealedMs, health.concealedMs);
  });

  test('local health round-trips through a confirmed receiver window', () {
    const health = MediaReceiveHealth(
      queuedMs: 80,
      underruns: 1,
      outputStarvations: 0,
      trims: 2,
      overflowDrops: 0,
      staleDrops: 3,
      duplicateDrops: 4,
      resyncs: 1,
      concealedMs: 20,
    );

    final window = MediaReceiverFeedbackAdapter.toWindow(
      MediaReceiverFeedbackAdapter.fromHealth(health),
    );

    expect(window.bidirectionalConfirmed, isTrue);
    expect(window.health.queuedMs, health.queuedMs);
    expect(window.health.underruns, health.underruns);
    expect(window.health.outputStarvations, health.outputStarvations);
    expect(window.health.trims, health.trims);
    expect(window.health.overflowDrops, health.overflowDrops);
    expect(window.health.staleDrops, health.staleDrops);
    expect(window.health.duplicateDrops, health.duplicateDrops);
    expect(window.health.resyncs, health.resyncs);
    expect(window.health.concealedMs, health.concealedMs);
  });

  test('one missing peer keeps a mixed-version room conservative', () {
    final windows = MediaReceiverFeedbackAdapter.toWindows([
      clean,
      null,
      clean,
    ]);
    final controller = MediaAdaptationController(
      cleanWindowsToUpgrade: 1,
      minimumUpgradeDwellMs: 0,
    );

    for (var i = 0; i < 5; i++) {
      final decision = controller.observe(receivers: windows, elapsedMs: 1000);
      expect(decision.tier, MediaAdaptationTier.unconfirmed);
      expect(decision.targetChannels, 1);
    }
  });

  test(
    'one distressed receiver protects two healthy receivers from max media',
    () {
      const distressed = MediaReceiverFeedback(
        queuedMs: 390,
        underruns: 0,
        outputStarvations: 0,
        trims: 0,
        overflowDrops: 1,
        staleDrops: 0,
        duplicateDrops: 0,
        resyncs: 0,
        concealedMs: 0,
      );
      final controller = MediaAdaptationController(
        cleanWindowsToUpgrade: 1,
        minimumUpgradeDwellMs: 0,
      );

      controller.observe(
        receivers: MediaReceiverFeedbackAdapter.toWindows([
          clean,
          clean,
          clean,
        ]),
        elapsedMs: 1000,
      );
      controller.observe(
        receivers: MediaReceiverFeedbackAdapter.toWindows([
          clean,
          clean,
          clean,
        ]),
        elapsedMs: 1000,
      );

      final decision = controller.observe(
        receivers: MediaReceiverFeedbackAdapter.toWindows([
          clean,
          distressed,
          clean,
        ]),
        elapsedMs: 1000,
      );

      expect(decision.tier, MediaAdaptationTier.suspended);
      expect(decision.reason, MediaAdaptationReason.severeReceiverDistress);
      expect(decision.shouldTransmit, isFalse);
    },
  );
}
