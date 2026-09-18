import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tark/core/audio/audio_format_profile.dart';
import 'package:tark/feature/audio/domain/media_frame_scheduler.dart';

const _stereoProfile = AudioFormatProfile(
  id: 900,
  sampleRateHz: 1000,
  channels: 2,
  frameDurationMs: 20,
  label: 'test-stereo',
  kind: AudioProfileKind.media,
);

const _monoProfile = AudioFormatProfile(
  id: 901,
  sampleRateHz: 1000,
  channels: 1,
  frameDurationMs: 20,
  label: 'test-mono',
  kind: AudioProfileKind.media,
);

/// Interleaved stereo capture chunk of [frames] L/R pairs, [l]/[r] each.
List<double> _stereoChunk(int frames, {double l = 1.0, double r = 3.0}) =>
    List.generate(frames * 2, (i) => i.isEven ? l : r);

void main() {
  // captureSampleRateHz=1000, captureChannels=2 -> 2 samples/ms of capture.
  // profile.frameSamples = 20 (1000Hz * 20ms), so one wire frame needs 40
  // interleaved capture samples regardless of the target profile's own
  // channel count (downmix, if any, happens after the pull).
  MediaFrameScheduler build({
    AudioFormatProfile profile = _stereoProfile,
    required List<List<double>> sent,
    int prefillMs = 25,
    int highWaterMs = 40,
    int floodMs = 100,
  }) => MediaFrameScheduler(
    profile: profile,
    sendFrame: (samples) => sent.add(samples),
    captureSampleRateHz: 1000,
    captureChannels: 2,
    prefillMs: prefillMs,
    highWaterMs: highWaterMs,
    floodMs: floodMs,
  );

  group('cushion', () {
    test('withholds sending until the cushion has filled', () {
      fakeAsync((async) {
        final sent = <List<double>>[];
        final scheduler = build(sent: sent)..start();
        addTearDown(scheduler.dispose);

        scheduler.addChunk(_stereoChunk(10)); // 20 samples, below prefill(50)
        async.elapse(const Duration(milliseconds: 20));
        expect(sent, isEmpty);
        expect(scheduler.isPriming, isTrue);

        scheduler.addChunk(_stereoChunk(20)); // 40 more -> 60 total, past 50
        async.elapse(const Duration(milliseconds: 20));
        expect(sent, isNotEmpty);
        expect(scheduler.isPriming, isFalse);
      });
    });

    test(
      'a starved tick sends nothing and re-primes, counted once',
      () {
        fakeAsync((async) {
          final sent = <List<double>>[];
          final scheduler = build(sent: sent)..start();
          addTearDown(scheduler.dispose);

          // 60 interleaved samples: past the 50-sample prefill and enough
          // for one 40-sample frame, with 20 left over.
          scheduler.addChunk(_stereoChunk(30));
          async.elapse(const Duration(milliseconds: 20));
          expect(sent, hasLength(1));
          expect(scheduler.dropouts, 0);

          // Nothing left to feed the next tick.
          async.elapse(const Duration(milliseconds: 20));
          expect(sent, hasLength(1), reason: 'a starved tick sends nothing');
          expect(scheduler.dropouts, 1);
          expect(scheduler.isPriming, isTrue);

          // Still empty: already priming, so this is the same dropout.
          async.elapse(const Duration(milliseconds: 20));
          expect(scheduler.dropouts, 1);
        });
      },
    );

    test('clear returns the scheduler to priming and empties the queue', () {
      fakeAsync((async) {
        final sent = <List<double>>[];
        final scheduler = build(sent: sent)..start();
        addTearDown(scheduler.dispose);

        scheduler.addChunk(_stereoChunk(30));
        scheduler.clear();
        expect(scheduler.isPriming, isTrue);
        expect(scheduler.queuedSamples, 0);

        async.elapse(const Duration(milliseconds: 20));
        expect(sent, isEmpty);
      });
    });
  });

  group('drift', () {
    test('trims back toward the prefill above the high-water mark', () {
      fakeAsync((async) {
        final sent = <List<double>>[];
        final scheduler = build(sent: sent)..start();
        addTearDown(scheduler.dispose);

        scheduler.addChunk(_stereoChunk(75)); // 150 samples, over 80 high-water
        async.elapse(const Duration(milliseconds: 20));

        expect(scheduler.trims, 1);
        expect(scheduler.floods, 0);
        // 150 - 20 (one trim step) - 40 (one sent frame) = 90.
        expect(scheduler.queuedSamples, 90);
      });
    });

    test('a backlog past the flood threshold is dropped in one splice', () {
      fakeAsync((async) {
        final sent = <List<double>>[];
        final scheduler = build(sent: sent)..start();
        addTearDown(scheduler.dispose);

        scheduler.addChunk(_stereoChunk(150)); // 300 samples, over flood(200)
        async.elapse(const Duration(milliseconds: 20));

        expect(scheduler.floods, 1);
        expect(scheduler.trims, 0, reason: 'a backlog is not drift');
        expect(
          scheduler.queuedSamples,
          lessThanOrEqualTo(scheduler.prefillSamples),
          reason: 'one splice lands back at the cushion, not near the cap',
        );
      });
    });
  });

  group('queue cap', () {
    test('drops the oldest samples over maxQueuedSamples', () {
      final sent = <List<double>>[];
      final scheduler = build(sent: sent);
      addTearDown(scheduler.dispose);

      // maxQueuedSamples = 2 samples/ms * 1000ms = 2000.
      scheduler.addChunk(_stereoChunk(1250)); // 2500 interleaved samples
      expect(scheduler.overflowDrops, 1);
      expect(scheduler.queuedSamples, 2000);
    });
  });

  group('channel handling', () {
    test('a stereo profile sends the raw interleaved frame unchanged', () {
      fakeAsync((async) {
        final sent = <List<double>>[];
        final scheduler = build(profile: _stereoProfile, sent: sent)
          ..start();
        addTearDown(scheduler.dispose);

        scheduler.addChunk(_stereoChunk(30, l: 1.0, r: 3.0));
        async.elapse(const Duration(milliseconds: 20));

        expect(sent, hasLength(1));
        expect(sent.single, hasLength(40));
        expect(sent.single.take(4), [1.0, 3.0, 1.0, 3.0]);
      });
    });

    test('a mono profile downmixes before sending', () {
      fakeAsync((async) {
        final sent = <List<double>>[];
        final scheduler = build(profile: _monoProfile, sent: sent)..start();
        addTearDown(scheduler.dispose);

        scheduler.addChunk(_stereoChunk(30, l: 1.0, r: 3.0));
        async.elapse(const Duration(milliseconds: 20));

        expect(sent, hasLength(1));
        expect(sent.single, hasLength(20));
        expect(sent.single, everyElement(closeTo(2.0, 1e-9)));
      });
    });
  });

  group('lifecycle', () {
    test('start/stop control whether the clock is running', () {
      fakeAsync((async) {
        final sent = <List<double>>[];
        final scheduler = build(sent: sent);
        addTearDown(scheduler.dispose);
        expect(scheduler.isRunning, isFalse);

        scheduler.start();
        expect(scheduler.isRunning, isTrue);

        scheduler.addChunk(_stereoChunk(30));
        async.elapse(const Duration(milliseconds: 20));
        expect(sent, hasLength(1));

        scheduler.stop();
        expect(scheduler.isRunning, isFalse);
        scheduler.addChunk(_stereoChunk(30));
        async.elapse(const Duration(milliseconds: 100));
        expect(sent, hasLength(1), reason: 'a stopped clock sends nothing');
      });
    });

    test('dispose stops the clock and discards buffered audio', () {
      fakeAsync((async) {
        final sent = <List<double>>[];
        final scheduler = build(sent: sent)..start();

        scheduler.addChunk(_stereoChunk(10));
        scheduler.dispose();

        expect(scheduler.isRunning, isFalse);
        expect(scheduler.queuedSamples, 0);
        async.elapse(const Duration(milliseconds: 100));
        expect(sent, isEmpty);
      });
    });
  });
}
