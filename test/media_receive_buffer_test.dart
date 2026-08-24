import 'package:flutter_test/flutter_test.dart';
import 'package:tark/feature/audio/domain/media_receive_buffer.dart';

List<double> _tone(int n, {double level = 0.5}) =>
    List<double>.filled(n, level);

void main() {
  MediaReceiveBuffer build({
    int targetBufferMs = 10,
    int maxQueueMs = 100,
    int maxConcealMs = 2,
  }) => MediaReceiveBuffer(
    sampleRate: 1000,
    targetBufferMs: targetBufferMs,
    maxQueueMs: maxQueueMs,
    maxConcealMs: maxConcealMs,
  );

  group('filling', () {
    test('waits for the target cushion before playback', () {
      final buffer = build();
      addTearDown(buffer.dispose);

      buffer.feed(_tone(5), 0, 'peer');
      expect(buffer.pullFrame(5), isNull);
      expect(buffer.isFilling, isTrue);

      buffer.feed(_tone(5), 1, 'peer');
      expect(buffer.pullFrame(5), hasLength(5));
      expect(buffer.isFilling, isFalse);
    });
  });

  group('sequence semantics', () {
    test('conceals only a tiny gap', () {
      final buffer = build(targetBufferMs: 1000, maxConcealMs: 5);
      addTearDown(buffer.dispose);

      buffer.feed(_tone(5, level: 1), 0, 'peer');
      buffer.feed(_tone(5, level: 1), 2, 'peer');

      expect(buffer.concealedSamples, 5);
      expect(buffer.queuedSamples, 15);
      expect(buffer.resyncs, 0);
    });

    test('a large forward gap drops stale backlog and resyncs to live edge', () {
      final buffer = build(targetBufferMs: 1000, maxConcealMs: 5);
      addTearDown(buffer.dispose);

      buffer.feed(_tone(5, level: 0.1), 0, 'peer');
      buffer.feed(_tone(5, level: 0.2), 1, 'peer');
      buffer.feed(_tone(5, level: 0.9), 20, 'peer');

      expect(buffer.resyncs, 1);
      expect(buffer.concealedSamples, 0);
      expect(buffer.queuedSamples, 5);
    });

    test('a duplicate is rejected and counted', () {
      final buffer = build(targetBufferMs: 1000);
      addTearDown(buffer.dispose);

      buffer.feed(_tone(5), 0, 'peer');
      buffer.feed(_tone(5), 0, 'peer');

      expect(buffer.duplicateDrops, 1);
      expect(buffer.staleDrops, 0);
      expect(buffer.queuedSamples, 5);
    });

    test('ordinary reorder is stale and cannot re-enter playback', () {
      final buffer = build(targetBufferMs: 1000);
      addTearDown(buffer.dispose);

      buffer.feed(_tone(5), 0, 'peer');
      buffer.feed(_tone(5), 1, 'peer');
      buffer.feed(_tone(5), 3, 'peer');
      buffer.feed(_tone(5), 2, 'peer');

      expect(buffer.staleDrops, 1);
      expect(buffer.queuedSamples, 5);
      expect(buffer.resyncs, 1);
    });

    test('a far-behind packet cannot impersonate a sender restart', () {
      final buffer = build(targetBufferMs: 1000);
      addTearDown(buffer.dispose);

      buffer.feed(_tone(5), 500, 'peer');
      buffer.feed(_tone(5), 0, 'peer');
      buffer.feed(_tone(5), 501, 'peer');

      expect(buffer.staleDrops, 1);
      expect(buffer.queuedSamples, 10);
    });

    test('explicit reset permits a real sender restart', () {
      final buffer = build(targetBufferMs: 1000);
      addTearDown(buffer.dispose);

      buffer.feed(_tone(5), 500, 'peer');
      buffer.reset();
      buffer.feed(_tone(5), 0, 'peer');

      expect(buffer.staleDrops, 0);
      expect(buffer.queuedSamples, 5);
    });

    test('senders keep independent sequence state', () {
      final buffer = build(targetBufferMs: 1000);
      addTearDown(buffer.dispose);

      buffer.feed(_tone(5), 8, 'a');
      buffer.feed(_tone(5), 0, 'b');
      buffer.feed(_tone(5), 9, 'a');
      buffer.feed(_tone(5), 1, 'b');

      expect(buffer.queuedSamples, 20);
      expect(buffer.staleDrops, 0);
    });
  });

  group('bounded latency and drift', () {
    test('hard cap always keeps queue inside maxQueueMs', () {
      final buffer = build(targetBufferMs: 10, maxQueueMs: 40);
      addTearDown(buffer.dispose);

      buffer.feed(_tone(200), 0, 'peer');

      expect(buffer.queuedMs, 40);
      expect(buffer.overflowDrops, 1);
    });

    test('mild queue growth is corrected gradually', () {
      final buffer = build(targetBufferMs: 20, maxQueueMs: 100);
      addTearDown(buffer.dispose);

      buffer.feed(_tone(40), 0, 'peer');
      final before = buffer.queuedSamples;
      expect(buffer.pullFrame(5), hasLength(5));

      expect(buffer.trims, 1);
      expect(buffer.queuedSamples, lessThan(before - 5));
      expect(buffer.queuedSamples, greaterThanOrEqualTo(buffer.targetSamples));
    });

    test('severe burst after backgrounding is collapsed in one pull', () {
      final buffer = build(targetBufferMs: 20, maxQueueMs: 100);
      addTearDown(buffer.dispose);

      buffer.feed(_tone(90), 0, 'peer');
      expect(buffer.pullFrame(5), hasLength(5));

      expect(buffer.trims, 1);
      expect(buffer.queuedSamples, lessThanOrEqualTo(buffer.targetSamples));
    });

    test('starvation re-primes instead of repeatedly manufacturing output', () {
      final buffer = build(targetBufferMs: 20);
      addTearDown(buffer.dispose);

      buffer.feed(_tone(20), 0, 'peer');
      expect(buffer.pullFrame(5), hasLength(5));
      expect(buffer.pullFrame(20), isNull);
      expect(buffer.underruns, 1);
      expect(buffer.isFilling, isTrue);
      expect(buffer.pullFrame(20), isNull);
      expect(buffer.underruns, 1);
    });
  });

  group('health', () {
    test('snapshot exposes bounded privacy-safe receiver evidence', () {
      final buffer = build(targetBufferMs: 10, maxQueueMs: 20);
      addTearDown(buffer.dispose);

      buffer.feed(_tone(30), 0, 'peer');
      buffer.feed(_tone(5), 0, 'peer');
      final health = buffer.health;

      expect(health.queuedMs, lessThanOrEqualTo(20));
      expect(health.overflowDrops, 1);
      expect(health.duplicateDrops, 1);
      expect(health.isDistressed, isTrue);
    });
  });

  group('reset', () {
    test('clears queue and sequence baseline but keeps session counters', () {
      final buffer = build(targetBufferMs: 0);
      addTearDown(buffer.dispose);

      buffer.feed(_tone(5), 5, 'peer');
      buffer.feed(_tone(5), 5, 'peer');
      buffer.reset();
      buffer.feed(_tone(5), 0, 'peer');

      expect(buffer.queuedSamples, 5);
      expect(buffer.duplicateDrops, 1);
    });
  });
}
