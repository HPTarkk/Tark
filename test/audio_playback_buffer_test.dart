import 'package:flutter_test/flutter_test.dart';
import 'package:tark/feature/audio/data/audio_playback_buffer.dart';

/// Records everything the buffer pushes toward the audio device.
class _RecordingSink implements Sink<List<double>> {
  final List<List<double>> chunks = [];

  int get totalSamples => chunks.fold(0, (sum, c) => sum + c.length);

  @override
  void add(List<double> data) => chunks.add(data);

  @override
  void close() {}
}

/// A block of non-silent audio, so silence in the output is unambiguous.
List<double> _tone(int n, {double level = 0.5}) =>
    List<double>.generate(n, (i) => level);

void main() {
  const rate = 48000;
  const drainMs = 10;
  const drainSize = rate * drainMs ~/ 1000; // 480
  const targetMs = 100;
  const targetSamples = rate * targetMs ~/ 1000; // 4800

  AudioPlaybackBuffer build(
    _RecordingSink sink, {
    int prefillMs = AudioPlaybackBuffer.kDefaultOutputPrefillMs,
  }) => AudioPlaybackBuffer(
    output: sink,
    sampleRate: rate,
    targetBufferMs: targetMs,
    drainIntervalMs: drainMs,
    outputPrefillMs: prefillMs,
  );

  /// Fills past the target so draining starts. [startSeq] must continue the
  /// sender's existing sequence — restarting it would make every chunk look
  /// stale and be dropped, which is correct behaviour but fills nothing.
  void fillToStart(
    AudioPlaybackBuffer buffer, {
    int chunk = 960,
    int startSeq = 0,
  }) {
    var seq = startSeq;
    var fed = 0;
    while (fed <= targetSamples) {
      buffer.feed(_tone(chunk), seq++, 'peer');
      fed += chunk;
    }
  }

  group('output prefill', () {
    test('pushes a silent cushion before the first audio slice', () {
      final sink = _RecordingSink();
      final buffer = build(sink);
      addTearDown(buffer.dispose);

      fillToStart(buffer);

      // The cushion is handed over synchronously when draining starts, before
      // any timer tick — that is the point, since the first late tick is as
      // likely to starve the device as any later one.
      expect(sink.chunks, isNotEmpty);
      final prefill = sink.chunks.first;
      expect(
        prefill.length,
        rate * AudioPlaybackBuffer.kDefaultOutputPrefillMs ~/ 1000,
      );
      expect(
        prefill.every((s) => s == 0.0),
        isTrue,
        reason: 'cushion must be silence, not duplicated audio',
      );
    });

    test('cushion means the device stays ahead by a full prefill', () async {
      final sink = _RecordingSink();
      final buffer = build(sink);
      addTearDown(buffer.dispose);

      fillToStart(buffer);
      // Keep feeding so the queue never runs dry over the observed window.
      var seq = 1000;
      for (var i = 0; i < 8; i++) {
        await Future<void>.delayed(const Duration(milliseconds: drainMs));
        buffer.feed(_tone(drainSize), seq++, 'peer');
      }

      final prefillSamples =
          rate * AudioPlaybackBuffer.kDefaultOutputPrefillMs ~/ 1000;
      // However many ticks actually fired, the device has been handed a whole
      // prefill more than the ticks alone would have produced.
      final ticksWorth = sink.totalSamples - prefillSamples;
      expect(ticksWorth, greaterThanOrEqualTo(0));
      expect(
        sink.totalSamples,
        greaterThanOrEqualTo(prefillSamples + drainSize),
        reason: 'cushion plus at least one drained slice should have gone out',
      );
    });

    test('prefill can be disabled', () async {
      final sink = _RecordingSink();
      final buffer = build(sink, prefillMs: 0);
      addTearDown(buffer.dispose);

      fillToStart(buffer);
      // Nothing goes out synchronously without a cushion — the device gets
      // its first samples only when the first tick fires. That gap is exactly
      // the old behaviour that let the ring sit at zero between ticks.
      expect(sink.chunks, isEmpty);

      await Future<void>.delayed(const Duration(milliseconds: 25));
      expect(sink.chunks, isNotEmpty);
      expect(sink.chunks.first.any((s) => s != 0.0), isTrue);
    });
  });

  group('underrun', () {
    test('ramps the final samples to zero instead of cutting mid-waveform',
        () async {
      final sink = _RecordingSink();
      final buffer = build(sink, prefillMs: 0);
      addTearDown(buffer.dispose);

      // Start draining, then stop feeding entirely so the queue runs dry.
      fillToStart(buffer);
      await Future<void>.delayed(const Duration(milliseconds: 300));

      expect(sink.chunks.length, greaterThan(1));
      final last = sink.chunks.last;
      expect(last, isNotEmpty);
      // A hard cut would leave the tail at full level; the ramp lands on zero.
      expect(
        last.last,
        closeTo(0.0, 1e-9),
        reason: 'final sample must be faded to zero to avoid a click',
      );
      expect(
        last.first,
        greaterThan(last.last),
        reason: 'ramp should descend across the tail',
      );
    });

    test('resumes with a fade-in after refilling', () async {
      final sink = _RecordingSink();
      final buffer = build(sink, prefillMs: 0);
      addTearDown(buffer.dispose);

      fillToStart(buffer);
      await Future<void>.delayed(const Duration(milliseconds: 300));
      final beforeRefill = sink.chunks.length;

      // Refill: draining restarts and the first slice out is ramped up.
      var seq = 5000;
      for (var i = 0; i < 12; i++) {
        buffer.feed(_tone(drainSize), seq++, 'peer');
      }
      await Future<void>.delayed(const Duration(milliseconds: 40));

      expect(sink.chunks.length, greaterThan(beforeRefill));
      final resumed = sink.chunks[beforeRefill];
      expect(
        resumed.first,
        lessThan(0.5),
        reason: 'resume must ramp up, not jump straight to full level',
      );
    });
  });

  group('sequence handling is unaffected by the cushion', () {
    test('a gap is concealed with silence, keeping timing intact', () async {
      final sink = _RecordingSink();
      final buffer = build(sink);
      addTearDown(buffer.dispose);

      final gapless = _RecordingSink();
      final reference = build(gapless);
      addTearDown(reference.dispose);
      reference.feed(_tone(480), 0, 'peer');
      reference.feed(_tone(480), 1, 'peer');
      fillToStart(reference, startSeq: 2);

      buffer.feed(_tone(480), 0, 'peer');
      buffer.feed(_tone(480), 3, 'peer'); // seq 1 and 2 lost
      fillToStart(buffer, startSeq: 4);

      // The two missing chunks were concealed with silence rather than
      // skipped, so the gapped stream carries MORE total audio than the
      // gapless one — that extra is the preserved timing.
      expect(
        buffer.queuedSamples,
        greaterThan(reference.queuedSamples),
        reason: 'lost packets must be concealed, not dropped',
      );

      await Future<void>.delayed(const Duration(milliseconds: 25));
      expect(sink.totalSamples, greaterThan(0));
    });

    test('stale packets are dropped rather than spliced in late', () async {
      final sink = _RecordingSink();
      final buffer = build(sink);
      addTearDown(buffer.dispose);

      buffer.feed(_tone(480), 5, 'peer');
      final afterFirst = buffer.queuedSamples;
      buffer.feed(_tone(480), 2, 'peer'); // stale — must be ignored
      expect(
        buffer.queuedSamples,
        afterFirst,
        reason: 'a packet older than what has been consumed must not queue',
      );

      fillToStart(buffer, startSeq: 6);
      await Future<void>.delayed(const Duration(milliseconds: 25));
      expect(sink.chunks, isNotEmpty);
    });
  });

  group('sender restarts its sequence counter', () {
    // A sequence counter lives on the transport repository and starts at zero,
    // while the sender's identity does not restart with it — so a counter far
    // behind the expected value is a new stream, not a late packet. Read as
    // lateness it was fatal: the stale branch returns without advancing the
    // expected sequence, so the sender never becomes un-stale and is muted for
    // the rest of the session, in one direction only.
    test('a counter restart resyncs instead of dropping', () {
      final sink = _RecordingSink();
      final buffer = build(sink);
      addTearDown(buffer.dispose);

      buffer.feed(_tone(480), 5000, 'peer');
      final afterFirst = buffer.queuedSamples;

      buffer.feed(_tone(480), 0, 'peer');
      expect(
        buffer.queuedSamples,
        greaterThan(afterFirst),
        reason: 'a restarted stream must be adopted, not discarded',
      );
    });

    test('and keeps accepting everything that follows', () {
      final sink = _RecordingSink();
      final buffer = build(sink);
      addTearDown(buffer.dispose);

      buffer.feed(_tone(480), 5000, 'peer');
      buffer.feed(_tone(480), 0, 'peer');

      // The actual defect: not one dropped packet, but every packet after it.
      var queued = buffer.queuedSamples;
      for (var seq = 1; seq <= 10; seq++) {
        buffer.feed(_tone(480), seq, 'peer');
        expect(
          buffer.queuedSamples,
          greaterThan(queued),
          reason: 'packet $seq after a resync must still be queued',
        );
        queued = buffer.queuedSamples;
      }
    });

    test('restarting one sender leaves the other alone', () {
      final sink = _RecordingSink();
      final buffer = build(sink);
      addTearDown(buffer.dispose);

      buffer.feed(_tone(480), 5000, 'a');
      buffer.feed(_tone(480), 7, 'b');
      buffer.feed(_tone(480), 0, 'a'); // a restarts

      final queued = buffer.queuedSamples;
      buffer.feed(_tone(480), 3, 'b'); // still stale for b, still dropped
      expect(buffer.queuedSamples, queued);
      buffer.feed(_tone(480), 8, 'b'); // b continues normally
      expect(buffer.queuedSamples, greaterThan(queued));
    });

    test('ordinary reordering is still treated as late, not as a restart', () {
      final sink = _RecordingSink();
      final buffer = build(sink);
      addTearDown(buffer.dispose);

      buffer.feed(_tone(480), 40, 'peer');
      final afterFirst = buffer.queuedSamples;
      // 39 behind: within the reorder window, so genuinely a late packet.
      buffer.feed(_tone(480), 2, 'peer');
      expect(buffer.queuedSamples, afterFirst);
    });
  });
}
