import 'package:flutter_test/flutter_test.dart';
import 'package:tark/feature/audio/domain/media_receive_buffer.dart';

List<double> _tone(int n, {double level = 0.5}) =>
    List<double>.filled(n, level);

void main() {
  // sampleRate=1000 -> 1 sample/ms, so target/max line up with small,
  // easy-to-read sample counts.
  MediaReceiveBuffer build({
    int targetBufferMs = 10,
    int maxQueueMs = 100,
  }) => MediaReceiveBuffer(
    sampleRate: 1000,
    targetBufferMs: targetBufferMs,
    maxQueueMs: maxQueueMs,
  );

  group('filling', () {
    test('pullFrame returns null before the cushion has filled', () {
      final buffer = build();
      addTearDown(buffer.dispose);

      buffer.feed(_tone(5), 0, 'peer'); // below the 10-sample target
      expect(buffer.pullFrame(5), isNull);
      expect(buffer.isFilling, isTrue);
    });

    test('pullFrame returns frames once the cushion has filled', () {
      final buffer = build();
      addTearDown(buffer.dispose);

      buffer.feed(_tone(10), 0, 'peer'); // exactly the target
      final out = buffer.pullFrame(5);
      expect(out, isNotNull);
      expect(out, hasLength(5));
      expect(buffer.isFilling, isFalse);
    });
  });

  group('sequence handling', () {
    // A large target relative to the content fed keeps every one of these
    // tests below the trim threshold, so only feed-side state — not the
    // trim/prime interaction pullFrame introduces — is under test here.
    const bigTarget = 1000;

    test('conceals an ordinary gap with silence', () {
      final buffer = build(targetBufferMs: bigTarget);
      addTearDown(buffer.dispose);

      buffer.feed(_tone(5, level: 1.0), 0, 'peer');
      buffer.feed(_tone(5, level: 1.0), 2, 'peer'); // one chunk missing
      expect(buffer.concealedSamples, 5); // one missing chunk of length 5
      expect(buffer.queuedSamples, 15); // 5 real + 5 silence + 5 real
    });

    test('a stale/late packet is dropped, not spliced in', () {
      final buffer = build(targetBufferMs: bigTarget);
      addTearDown(buffer.dispose);

      buffer.feed(_tone(5), 0, 'peer');
      buffer.feed(_tone(5), 1, 'peer');
      buffer.feed(_tone(5), 0, 'peer'); // stale — already past seq 0
      expect(buffer.queuedSamples, 10);
    });

    test('a gap too large to conceal resyncs without filling silence', () {
      final buffer = build(targetBufferMs: bigTarget);
      addTearDown(buffer.dispose);

      buffer.feed(_tone(5), 0, 'peer');
      buffer.feed(_tone(5), 1000, 'peer'); // far beyond the concealment cap
      // Only the two real chunks queued — no silence manufactured for the gap.
      expect(buffer.queuedSamples, 10);
      expect(buffer.concealedSamples, 0);
    });

    test('a far-behind jump resyncs immediately (no multi-packet confirm)', () {
      // Unlike AudioPlaybackBuffer, one far-behind packet is enough to adopt
      // a new baseline — see the class doc for why that's a deliberate
      // simplification here.
      final buffer = build(targetBufferMs: bigTarget);
      addTearDown(buffer.dispose);

      buffer.feed(_tone(5), 500, 'peer');
      buffer.feed(_tone(5), 0, 'peer'); // far behind 501 -> adopted at once
      buffer.feed(_tone(5), 1, 'peer'); // continues the new baseline
      expect(buffer.queuedSamples, 15);
    });

    test('independent sequence tracking per sender', () {
      final buffer = build(targetBufferMs: bigTarget);
      addTearDown(buffer.dispose);

      buffer.feed(_tone(5), 0, 'a');
      buffer.feed(_tone(5), 0, 'b'); // a fresh sender, not stale
      expect(buffer.queuedSamples, 10);
    });
  });

  group('drift and overflow', () {
    test('trims a backlog above twice the target', () {
      final buffer = build(targetBufferMs: 10); // target = 10 samples
      addTearDown(buffer.dispose);

      buffer.feed(_tone(30), 0, 'peer'); // 30 > 2x target (20)
      buffer.pullFrame(5);

      expect(buffer.trims, 1);
      // 30 - 10 (trim step) - 5 (pulled) = 15.
      expect(buffer.queuedSamples, 15);
    });

    test('drops the oldest samples over the queue cap', () {
      final buffer = build(targetBufferMs: 10, maxQueueMs: 20); // cap = 20
      addTearDown(buffer.dispose);

      buffer.feed(_tone(30), 0, 'peer');
      expect(buffer.overflowDrops, 1);
      expect(buffer.queuedSamples, 20);
    });
  });

  group('starvation', () {
    test('a starved pull re-primes and counts one underrun', () {
      // Realistic shape: target well above one pull's count, same as
      // production (a ~150ms cushion pulled in ~10ms slices) — the case
      // where a single pull could exceed the whole cushion isn't one this
      // buffer is meant to handle any more than AudioPlaybackBuffer's
      // equivalent drain-vs-target ratio is.
      final buffer = build(targetBufferMs: 20);
      addTearDown(buffer.dispose);

      buffer.feed(_tone(20), 0, 'peer'); // fills to target
      expect(buffer.pullFrame(5), hasLength(5)); // drains to 15 left
      expect(buffer.pullFrame(20), isNull); // not enough for a 20-sample pull
      expect(buffer.underruns, 1);
      expect(buffer.isFilling, isTrue);

      // Still nothing new fed — the same starvation, filling absorbs it.
      expect(buffer.pullFrame(20), isNull);
      expect(buffer.underruns, 1);
    });
  });

  group('reset', () {
    test('clears the queue and per-sender sequence state', () {
      final buffer = build(targetBufferMs: 0);
      addTearDown(buffer.dispose);

      buffer.feed(_tone(5), 5, 'peer');
      buffer.reset();

      expect(buffer.queuedSamples, 0);
      expect(buffer.isFilling, isTrue);
      // Sequence state cleared: seq 0 is no longer "stale" for this sender.
      buffer.feed(_tone(5), 0, 'peer');
      expect(buffer.queuedSamples, 5);
    });
  });
}
