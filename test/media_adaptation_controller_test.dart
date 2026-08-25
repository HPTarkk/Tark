import 'package:flutter_test/flutter_test.dart';
import 'package:tark/feature/audio/domain/media_adaptation_controller.dart';
import 'package:tark/feature/audio/domain/media_receive_buffer.dart';

void main() {
  MediaReceiveHealth health({
    int queuedMs = 120,
    int underruns = 0,
    int outputStarvations = 0,
    int trims = 0,
    int overflowDrops = 0,
    int staleDrops = 0,
    int duplicateDrops = 0,
    int resyncs = 0,
    int concealedMs = 0,
  }) => MediaReceiveHealth(
    queuedMs: queuedMs,
    underruns: underruns,
    outputStarvations: outputStarvations,
    trims: trims,
    overflowDrops: overflowDrops,
    staleDrops: staleDrops,
    duplicateDrops: duplicateDrops,
    resyncs: resyncs,
    concealedMs: concealedMs,
  );

  MediaReceiverWindow receiver({
    bool confirmed = true,
    MediaReceiveHealth? value,
  }) => MediaReceiverWindow(
    health: value ?? health(),
    bidirectionalConfirmed: confirmed,
  );

  test('unconfirmed feedback never selects maximum stereo tier', () {
    final controller = MediaAdaptationController();

    final decision = controller.observe(
      receivers: [receiver(confirmed: false)],
      elapsedMs: 2000,
    );

    expect(decision.tier, MediaAdaptationTier.unconfirmed);
    expect(decision.targetBitrateKbps, 48);
    expect(decision.targetChannels, 1);
  });

  test('first confirmed clean window enters conservative tier', () {
    final controller = MediaAdaptationController();

    final decision = controller.observe(
      receivers: [receiver()],
      elapsedMs: 1000,
    );

    expect(decision.tier, MediaAdaptationTier.conservative);
    expect(decision.reason, MediaAdaptationReason.confirmedClean);
  });

  test('clean sustained evidence upgrades gradually with dwell', () {
    final controller = MediaAdaptationController(
      cleanWindowsToUpgrade: 2,
      minimumUpgradeDwellMs: 2000,
    );
    controller.observe(receivers: [receiver()], elapsedMs: 1000);

    final held = controller.observe(receivers: [receiver()], elapsedMs: 1000);
    expect(held.tier, MediaAdaptationTier.conservative);

    final balanced = controller.observe(
      receivers: [receiver()],
      elapsedMs: 1000,
    );
    expect(balanced.tier, MediaAdaptationTier.balanced);

    controller.observe(receivers: [receiver()], elapsedMs: 1000);
    final high = controller.observe(receivers: [receiver()], elapsedMs: 1000);
    expect(high.tier, MediaAdaptationTier.high);
    expect(high.targetBitrateKbps, 96);
    expect(high.targetChannels, 2);
  });

  test('brief receiver spike does not flap room tier', () {
    final controller = MediaAdaptationController(
      cleanWindowsToUpgrade: 1,
      minimumUpgradeDwellMs: 0,
      distressWindowsToDegrade: 2,
    );
    controller.observe(receivers: [receiver()], elapsedMs: 1000);
    controller.observe(receivers: [receiver()], elapsedMs: 1000);
    expect(controller.tier, MediaAdaptationTier.balanced);

    final spike = controller.observe(
      receivers: [receiver(value: health(underruns: 1))],
      elapsedMs: 1000,
    );

    expect(spike.tier, MediaAdaptationTier.balanced);
    expect(spike.reason, MediaAdaptationReason.dwellHold);
  });

  test('persistent weak receiver lowers shared room floor once', () {
    final controller = MediaAdaptationController(
      cleanWindowsToUpgrade: 1,
      minimumUpgradeDwellMs: 0,
      distressWindowsToDegrade: 2,
    );
    controller.observe(receivers: [receiver()], elapsedMs: 1000);
    controller.observe(receivers: [receiver()], elapsedMs: 1000);
    controller.observe(receivers: [receiver()], elapsedMs: 1000);
    expect(controller.tier, MediaAdaptationTier.high);

    final weak = receiver(value: health(underruns: 1));
    controller.observe(
      receivers: [weak, receiver(), receiver()],
      elapsedMs: 1000,
    );
    final degraded = controller.observe(
      receivers: [weak, receiver(), receiver()],
      elapsedMs: 1000,
    );

    expect(degraded.tier, MediaAdaptationTier.balanced);
    expect(degraded.reason, MediaAdaptationReason.receiverDistress);
  });

  test('severe receiver distress suspends media before voice', () {
    final controller = MediaAdaptationController();
    controller.observe(receivers: [receiver()], elapsedMs: 1000);

    final decision = controller.observe(
      receivers: [receiver(value: health(overflowDrops: 1))],
      elapsedMs: 1000,
    );

    expect(decision.tier, MediaAdaptationTier.suspended);
    expect(decision.shouldTransmit, isFalse);
    expect(decision.reason, MediaAdaptationReason.severeReceiverDistress);
  });

  test('voice impairment always suspends Shared Music immediately', () {
    final controller = MediaAdaptationController();
    controller.observe(receivers: [receiver()], elapsedMs: 1000);

    final decision = controller.observe(
      receivers: [receiver()],
      elapsedMs: 1,
      voiceImpaired: true,
    );

    expect(decision.tier, MediaAdaptationTier.suspended);
    expect(decision.reason, MediaAdaptationReason.voiceProtection);
  });

  test('suspended media probes conservatively after clean recovery dwell', () {
    final controller = MediaAdaptationController(suspensionProbeDwellMs: 2000);
    controller.observe(
      receivers: [receiver(value: health(resyncs: 1))],
      elapsedMs: 1000,
    );

    final held = controller.observe(receivers: [receiver()], elapsedMs: 1000);
    expect(held.tier, MediaAdaptationTier.suspended);

    final recovered = controller.observe(
      receivers: [receiver()],
      elapsedMs: 1000,
    );
    expect(recovered.tier, MediaAdaptationTier.conservative);
    expect(recovered.reason, MediaAdaptationReason.recoveryProbe);
  });

  test('reset returns deterministic replay to unconfirmed state', () {
    final controller = MediaAdaptationController(
      cleanWindowsToUpgrade: 1,
      minimumUpgradeDwellMs: 0,
    );
    controller.observe(receivers: [receiver()], elapsedMs: 1000);
    controller.observe(receivers: [receiver()], elapsedMs: 1000);
    expect(controller.tier, MediaAdaptationTier.balanced);

    controller.reset();
    final replay = controller.observe(
      receivers: [receiver(confirmed: false)],
      elapsedMs: 1000,
    );

    expect(replay.tier, MediaAdaptationTier.unconfirmed);
    expect(replay.reason, MediaAdaptationReason.feedbackUnconfirmed);
  });
}
