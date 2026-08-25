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

  test('notification access missing remains silent/unknown, not blocked', () {
    final result = classifier.classify(
      evidence(mediaKnown: false, mediaPlaying: false),
    );
    expect(result.state, CaptureHealthState.silentIdle);
    expect(result.mayTransmitMedia, isFalse);
  });

  test('confirmed external media plus silence is blocked', () {
    final result = classifier.classify(evidence(mediaPlaying: true));
    expect(result.state, CaptureHealthState.blockedWhileMediaPlaying);
    expect(result.needsUserAction, isTrue);
    expect(result.mayTransmitMedia, isFalse);
  });

  test('audible capture is media-safe', () {
    final result = classifier.classify(
      evidence(rms: 0.2, mediaPlaying: true),
      firstAudibleFrameAtMs: 640,
    );
    expect(result.state, CaptureHealthState.audible);
    expect(result.mayTransmitMedia, isTrue);
    expect(result.timeToFirstAudibleFrameMs, 640);
  });

  test('stale last audible frame becomes stalled', () {
    final result = classifier.classify(
      evidence(sinceFrame: 1500, rms: 0.2, mediaPlaying: false),
    );
    expect(result.state, CaptureHealthState.stalled);
    expect(result.mayTransmitMedia, isFalse);
  });

  test('startup grace avoids premature blocked classification', () {
    final result = classifier.classify(
      evidence(elapsedMs: 200, mediaPlaying: true),
    );
    expect(result.state, CaptureHealthState.starting);
  });

  test('user stop disables transmission', () {
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

  group('CaptureHealthMonitor', () {
    final t0 = DateTime.utc(2026, 8, 25, 10);

    CaptureHealthMonitor monitor() => CaptureHealthMonitor(
      classifier: const CaptureHealthClassifier(
        firstFrameGraceMs: 100,
        stallAfterMs: 200,
        audibleRmsFloor: 0.01,
      ),
    );

    test('first audible frame records time and enables media', () {
      final health = monitor()..start(t0, supported: true);

      final result = health.observeFrame(
        const [0.2, -0.2, 0.2, -0.2],
        t0.add(const Duration(milliseconds: 120)),
        mediaPlayingKnown: true,
        externalMediaPlaying: true,
      );

      expect(result.state, CaptureHealthState.audible);
      expect(result.mayTransmitMedia, isTrue);
      expect(result.timeToFirstAudibleFrameMs, 120);
    });

    test('confirmed playing plus silent frames is blocked and not transmittable', () {
      final health = monitor()..start(t0, supported: true);

      final result = health.observeFrame(
        const [0.0, 0.0, 0.0],
        t0.add(const Duration(milliseconds: 120)),
        mediaPlayingKnown: true,
        externalMediaPlaying: true,
      );

      expect(result.state, CaptureHealthState.blockedWhileMediaPlaying);
      expect(result.mayTransmitMedia, isFalse);
    });

    test('lack of notification access never invents blocked state', () {
      final health = monitor()..start(t0, supported: true);

      final result = health.observeFrame(
        const [0.0, 0.0],
        t0.add(const Duration(milliseconds: 120)),
        mediaPlayingKnown: false,
        externalMediaPlaying: false,
      );

      expect(result.state, CaptureHealthState.silentIdle);
      expect(result.reasonCode, 'capture_silent_idle');
    });

    test('audible capture transitions to stalled when callbacks stop', () {
      final health = monitor()..start(t0, supported: true);
      health.observeFrame(
        const [0.2, -0.2],
        t0.add(const Duration(milliseconds: 120)),
        mediaPlayingKnown: true,
        externalMediaPlaying: true,
      );

      final stalled = health.snapshot(
        t0.add(const Duration(milliseconds: 350)),
        mediaPlayingKnown: true,
        externalMediaPlaying: true,
      );

      expect(stalled.state, CaptureHealthState.stalled);
      expect(stalled.mayTransmitMedia, isFalse);
    });

    test('stop and unsupported are deterministic voice-only states', () {
      final health = monitor()..start(t0, supported: false);
      expect(
        health
            .snapshot(
              t0.add(const Duration(milliseconds: 200)),
              mediaPlayingKnown: false,
              externalMediaPlaying: false,
            )
            .state,
        CaptureHealthState.unsupported,
      );

      health.start(t0, supported: true);
      health.stop();
      expect(
        health
            .snapshot(
              t0.add(const Duration(milliseconds: 200)),
              mediaPlayingKnown: false,
              externalMediaPlaying: false,
            )
            .state,
        CaptureHealthState.stopped,
      );
    });
  });
}
