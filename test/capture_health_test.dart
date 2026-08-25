import 'package:flutter_test/flutter_test.dart';
import 'package:tark/feature/audio/domain/capture_health.dart';

void main() {
  const classifier = CaptureHealthClassifier(
    firstFrameGraceMs: 1000,
    stallAfterMs: 800,
    audibleRmsFloor: 0.01,
  );

  CaptureHealthEvidence evidence({
    bool started = true,
    int elapsedMs = 2000,
    int? sinceFrame = 100,
    double? rms = 0,
    bool mediaPlaying = false,
    bool mediaKnown = true,
    bool stopped = false,
    bool supported = true,
  }) => CaptureHealthEvidence(
    captureStarted: started,
    elapsedMs: elapsedMs,
    msSinceLastFrame: sinceFrame,
    lastFrameRms: rms,
    externalMediaPlaying: mediaPlaying,
    mediaPlayingKnown: mediaKnown,
    explicitlyStopped: stopped,
    supported: supported,
  );

  test(
    'notification access missing keeps silence idle/unknown, not blocked',
    () {
      final result = classifier.classify(
        evidence(mediaKnown: false, mediaPlaying: false),
      );

      expect(result.state, CaptureHealthState.silentIdle);
      expect(result.mayTransmitMedia, isFalse);
    },
  );

  test('confirmed external media plus silence is classified as blocked', () {
    final result = classifier.classify(evidence(mediaPlaying: true));

    expect(result.state, CaptureHealthState.blockedWhileMediaPlaying);
    expect(result.needsUserAction, isTrue);
    expect(result.mayTransmitMedia, isFalse);
  });

  test('audible frame wins once capture is actually delivering audio', () {
    final result = classifier.classify(
      evidence(rms: 0.2, mediaPlaying: true),
      firstAudibleFrameAtMs: 640,
    );

    expect(result.state, CaptureHealthState.audible);
    expect(result.mayTransmitMedia, isTrue);
    expect(result.timeToFirstAudibleFrameMs, 640);
  });

  test('mid-cast frame stall is distinct from silent idle', () {
    final result = classifier.classify(
      evidence(sinceFrame: 1500, rms: null, mediaPlaying: false),
    );

    expect(result.state, CaptureHealthState.stalled);
    expect(result.reasonCode, 'capture_frame_stalled');
    expect(result.mayTransmitMedia, isFalse);
  });

  test('startup grace does not prematurely call silence blocked', () {
    final result = classifier.classify(
      evidence(elapsedMs: 200, mediaPlaying: true),
    );

    expect(result.state, CaptureHealthState.starting);
  });

  test('user stop is explicit and terminal-looking to transmission policy', () {
    final result = classifier.classify(evidence(stopped: true, rms: 0.5));

    expect(result.state, CaptureHealthState.stopped);
    expect(result.mayTransmitMedia, isFalse);
  });

  test('unsupported capture is actionable voice-only fallback', () {
    final result = classifier.classify(evidence(supported: false));

    expect(result.state, CaptureHealthState.unsupported);
    expect(result.needsUserAction, isTrue);
    expect(result.mayTransmitMedia, isFalse);
  });
}
