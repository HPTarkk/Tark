import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tark/feature/audio/data/audio_playback_buffer.dart';

/// Stands in for the native output ring: holds whatever the buffer writes and
/// plays it back at exactly real time, one timer period at a time.
class _FakeDevice implements Sink<List<double>> {
  final List<double> played = [];
  final List<double> _ring = [];

  int get queued => _ring.length;

  @override
  void add(List<double> data) => _ring.addAll(data);

  /// Consumes [count] samples, recording zeros for any the ring lacked — the
  /// same thing the real playback callback does on an underrun.
  void consume(int count) {
    final n = count < _ring.length ? count : _ring.length;
    played.addAll(_ring.take(n));
    _ring.removeRange(0, n);
    for (var i = n; i < count; i++) {
      played.add(0.0);
    }
  }

  @override
  void close() {}
}

List<double> _tone(int n, {double level = 0.5}) =>
    List<double>.filled(n, level);

void main() {
  const rate = 48000;
  const drainMs = 10;
  const drainSize = rate * drainMs ~/ 1000; // 480
  const prefillSamples = rate * 30 ~/ 1000; // 1440

  AudioPlaybackBuffer build(
    Sink<List<double>> sink, {
    int Function()? queued,
  }) => AudioPlaybackBuffer(
    output: sink,
    sampleRate: rate,
    targetBufferMs: 100,
    drainIntervalMs: drainMs,
    adaptive: false,
    outputQueuedFrames: queued,
  );

  /// Biggest jump between two neighbouring samples: a click is a step.
  double largestStep(List<double> s) {
    var worst = 0.0;
    for (var i = 1; i < s.length; i++) {
      final d = (s[i] - s[i - 1]).abs();
      if (d > worst) worst = d;
    }
    return worst;
  }

  group('drain follows the device when it reports its queue', () {
    test('tops the native ring back up after a late tick', () {
      fakeAsync((async) {
        final device = _FakeDevice();
        final buffer = build(device, queued: () => device.queued);
        var seq = 0;
        for (var i = 0; i < 20; i++) {
          buffer.feed(_tone(960), seq++, 'peer');
        }
        expect(device.queued, prefillSamples);

        // The device plays 50 ms while the isolate is stuck, then the timer
        // gets one callback. A drain that pushes one slice per callback leaves
        // the ring 40 ms short from here on.
        device.consume(rate * 50 ~/ 1000);
        async.elapse(const Duration(milliseconds: drainMs));

        expect(
          device.queued,
          greaterThanOrEqualTo(prefillSamples),
          reason: 'the ring must be refilled to its cushion in one tick',
        );
        buffer.dispose();
      });
    });

    test('writes nothing while the ring is already full enough', () {
      fakeAsync((async) {
        final device = _FakeDevice();
        final buffer = build(device, queued: () => device.queued);
        var seq = 0;
        for (var i = 0; i < 20; i++) {
          buffer.feed(_tone(960), seq++, 'peer');
        }
        // Device stalls entirely: nothing consumed, ring already holds more
        // than cushion plus a slice after the first tick.
        async.elapse(const Duration(milliseconds: drainMs));
        final afterFirst = device.queued;
        async.elapse(const Duration(milliseconds: drainMs * 5));
        expect(device.queued, afterFirst);
        buffer.dispose();
      });
    });

    test('a steady stream plays with no gaps at all', () {
      fakeAsync((async) {
        final device = _FakeDevice();
        final buffer = build(device, queued: () => device.queued);
        var seq = 0;
        for (var i = 0; i < 6; i++) {
          buffer.feed(_tone(960), seq++, 'peer');
        }
        // 3 s of real time: the sender delivers 20 ms every 20 ms, the device
        // plays 10 ms every 10 ms.
        for (var t = 0; t < 300; t++) {
          if (t.isEven) buffer.feed(_tone(960), seq++, 'peer');
          device.consume(drainSize);
          async.elapse(const Duration(milliseconds: drainMs));
        }
        // Skip the silent prefill and the opening fade-in.
        final speech = device.played.sublist(prefillSamples + 480);
        expect(speech.where((s) => s == 0.0), isEmpty);
        buffer.dispose();
      });
    });
  });

  group('no clicks from buffer housekeeping', () {
    test('trimming a backlog never dips toward silence', () {
      fakeAsync((async) {
        final device = _FakeDevice();
        final buffer = build(device);
        var seq = 0;
        // Hold the queue near 300 ms: past twice the 100 ms target, so the
        // gentle trim runs, but short of the jump back to live.
        for (var i = 0; i < 15; i++) {
          buffer.feed(_tone(960), seq++, 'peer');
        }
        for (var t = 0; t < 100; t++) {
          if (t.isEven) buffer.feed(_tone(960), seq++, 'peer');
          async.elapse(const Duration(milliseconds: drainMs));
        }
        expect(buffer.queuedSamples, greaterThan(0));
        device.consume(device.queued);

        final speech = device.played.sublist(prefillSamples + 480);
        expect(speech, isNotEmpty);
        expect(
          speech.reduce((a, b) => a < b ? a : b),
          greaterThan(0.45),
          reason: 'a trim used to fade the next slice in from zero',
        );
        buffer.dispose();
      });
    });

    test('silence covering lost packets is ramped, not stepped into', () {
      fakeAsync((async) {
        final device = _FakeDevice();
        final buffer = build(device);
        buffer.feed(_tone(960), 0, 'peer');
        buffer.feed(_tone(960), 1, 'peer');
        buffer.feed(_tone(960), 4, 'peer'); // 2 and 3 lost
        var seq = 5;
        for (var i = 0; i < 6; i++) {
          buffer.feed(_tone(960), seq++, 'peer');
        }
        async.elapse(const Duration(milliseconds: 200));
        device.consume(device.queued);

        final speech = device.played.sublist(prefillSamples);
        expect(speech.where((s) => s == 0.0), isNotEmpty);
        expect(largestStep(speech), lessThan(0.05));
        buffer.dispose();
      });
    });

    test('the ramp never writes into the caller\'s list', () {
      final device = _FakeDevice();
      final buffer = build(device);
      buffer.feed(_tone(960), 0, 'peer');
      final after = _tone(960);
      buffer.feed(after, 3, 'peer');
      expect(after.every((s) => s == 0.5), isTrue);
      buffer.dispose();
    });

    test('a big backlog jumps back to live instead of lagging for seconds', () {
      fakeAsync((async) {
        final device = _FakeDevice();
        final buffer = build(device);
        var seq = 0;
        // A link that stalled and then flushed: 800 ms arrives at once.
        for (var i = 0; i < 40; i++) {
          buffer.feed(_tone(960), seq++, 'peer');
        }
        async.elapse(const Duration(milliseconds: 20));
        expect(
          buffer.queuedSamples,
          lessThanOrEqualTo(rate * 100 ~/ 1000),
          reason: 'one tick must bring the queue back to its 100 ms target',
        );
        device.consume(device.queued);
        final speech = device.played.sublist(prefillSamples + 480);
        expect(speech.reduce((a, b) => a < b ? a : b), greaterThan(0.45));
        buffer.dispose();
      });
    });
  });
}
