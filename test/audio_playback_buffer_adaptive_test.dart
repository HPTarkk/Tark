import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tark/feature/audio/data/audio_playback_buffer.dart';

/// Records everything the buffer pushes toward the audio device.
class _RecordingSink implements Sink<List<double>> {
  final List<List<double>> chunks = [];

  @override
  void add(List<double> data) => chunks.add(data);

  @override
  void close() {}
}

List<double> _tone(int n) => List<double>.filled(n, 0.5);

void main() {
  const rate = 48000;
  const drainMs = 10;
  const targetMs = 100;
  const targetSamples = rate * targetMs ~/ 1000; // 4800

  // The band the depth may travel, from the ratios anchored on the configured
  // depth. At the default 100 ms this is the roadmap's 60–180 ms band.
  const minMs = 60;
  const maxMs = 180;

  AudioPlaybackBuffer build(_RecordingSink sink, {bool adaptive = true}) =>
      AudioPlaybackBuffer(
        output: sink,
        sampleRate: rate,
        targetBufferMs: targetMs,
        drainIntervalMs: drainMs,
        // No cushion: it is silence pushed to the device and would only add
        // noise to what these tests are counting.
        outputPrefillMs: 0,
        adaptive: adaptive,
      );

  /// Feeds enough to pass the target so draining starts.
  void fillToStart(AudioPlaybackBuffer buffer, {int startSeq = 0}) {
    const chunk = 960;
    var seq = startSeq;
    var fed = 0;
    while (fed <= targetSamples) {
      buffer.feed(_tone(chunk), seq++, 'peer');
      fed += chunk;
    }
  }

  group('adaptive depth', () {
    test('starts at the configured depth', () {
      final buffer = build(_RecordingSink());
      addTearDown(buffer.dispose);
      expect(buffer.targetBufferMs, targetMs);
    });

    // Being too shallow is audible immediately — the drain stops and the
    // listener hears speech chopped — so this must not wait for a window.
    test('grows the moment the queue runs dry', () {
      fakeAsync((async) {
        final buffer = build(_RecordingSink());
        addTearDown(buffer.dispose);

        fillToStart(buffer);
        expect(buffer.targetBufferMs, targetMs);

        // Feed nothing further; the drain empties the queue and underruns.
        async.elapse(const Duration(milliseconds: 500));
        expect(buffer.targetBufferMs, greaterThan(targetMs));
      });
    });

    test('growth stops at the top of the band', () {
      fakeAsync((async) {
        final buffer = build(_RecordingSink());
        addTearDown(buffer.dispose);

        // Repeatedly fill and starve, so the buffer underruns over and over.
        var seq = 0;
        for (var round = 0; round < 20; round++) {
          const chunk = 960;
          var fed = 0;
          while (fed <= targetSamples * 2) {
            buffer.feed(_tone(chunk), seq++, 'peer');
            fed += chunk;
          }
          async.elapse(const Duration(milliseconds: 500));
        }
        expect(buffer.targetBufferMs, maxMs);
      });
    });

    // Being too deep is a slowly-annoying delay rather than an audible fault,
    // so the depth is only given back after a sustained stretch with nothing
    // wrong — never after a single quiet window.
    test('shrinks only after a sustained calm stretch', () {
      fakeAsync((async) {
        final buffer = build(_RecordingSink());
        addTearDown(buffer.dispose);

        // Keep the queue comfortably fed so it never underruns and no packet
        // ever arrives late.
        var seq = 0;
        fillToStart(buffer, startSeq: seq);
        seq = 6;

        // One window is not enough.
        for (var tick = 0; tick < 200; tick++) {
          buffer.feed(_tone(480), seq++, 'peer');
          async.elapse(const Duration(milliseconds: drainMs));
        }
        expect(
          buffer.targetBufferMs,
          targetMs,
          reason: 'one calm window must not be enough to give depth back',
        );

        // Several more are.
        for (var tick = 0; tick < 1000; tick++) {
          buffer.feed(_tone(480), seq++, 'peer');
          async.elapse(const Duration(milliseconds: drainMs));
        }
        expect(buffer.targetBufferMs, lessThan(targetMs));
      });
    });

    test('shrinking stops at the bottom of the band', () {
      fakeAsync((async) {
        final buffer = build(_RecordingSink());
        addTearDown(buffer.dispose);

        var seq = 0;
        fillToStart(buffer, startSeq: seq);
        seq = 6;
        for (var tick = 0; tick < 20000; tick++) {
          buffer.feed(_tone(480), seq++, 'peer');
          async.elapse(const Duration(milliseconds: drainMs));
        }
        expect(buffer.targetBufferMs, minMs);
      });
    });

    test('a pinned buffer never moves', () {
      fakeAsync((async) {
        final buffer = build(_RecordingSink(), adaptive: false);
        addTearDown(buffer.dispose);

        fillToStart(buffer);
        async.elapse(const Duration(seconds: 2));
        expect(buffer.targetBufferMs, targetMs);
      });
    });

    // A reconnect mid-ride is overwhelmingly the same link with the same
    // jitter. Relearning the depth would be paid for in underruns, which are
    // audible, to save a latency nobody notices.
    test('a reset keeps the depth the link has already taught it', () {
      fakeAsync((async) {
        final buffer = build(_RecordingSink());
        addTearDown(buffer.dispose);

        fillToStart(buffer);
        async.elapse(const Duration(milliseconds: 500));
        final learned = buffer.targetBufferMs;
        expect(learned, greaterThan(targetMs));

        buffer.reset();
        expect(buffer.targetBufferMs, learned);
      });
    });
  });
}
