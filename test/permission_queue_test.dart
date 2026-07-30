import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:tark/core/utils/permission_queue.dart';

void main() {
  group('PermissionQueue', () {
    test('does not start a request while another is in flight', () async {
      final started = <String>[];
      final first = Completer<int>();
      final second = Completer<int>();

      final firstResult = PermissionQueue.run(() {
        started.add('first');
        return first.future;
      });
      final secondResult = PermissionQueue.run(() {
        started.add('second');
        return second.future;
      });

      await pumpMicrotasks();
      // This is the whole point: Android drops a second requestPermissions()
      // raised while the first dialog is up, and permission_handler never
      // completes the Future for the one that was dropped.
      expect(started, ['first']);

      first.complete(1);
      expect(await firstResult, 1);

      await pumpMicrotasks();
      expect(started, ['first', 'second']);

      second.complete(2);
      expect(await secondResult, 2);
    });

    test('a failed request still releases the queue', () async {
      final failing = PermissionQueue.run<int>(
        () => Future<int>.error(StateError('denied')),
      );
      await expectLater(failing, throwsStateError);

      expect(await PermissionQueue.run(() async => 7), 7);
    });

    test('a request that throws synchronously still releases the queue',
        () async {
      final throwing = PermissionQueue.run<int>(
        () => throw StateError('channel gone'),
      );
      await expectLater(throwing, throwsStateError);

      expect(await PermissionQueue.run(() async => 9), 9);
    });

    test('results are delivered to their own caller, in order', () async {
      final results = await Future.wait([
        PermissionQueue.run(() async => 'a'),
        PermissionQueue.run(() async => 'b'),
        PermissionQueue.run(() async => 'c'),
      ]);

      expect(results, ['a', 'b', 'c']);
    });
  });
}

/// Lets every pending microtask (and the queue's own chaining) settle.
Future<void> pumpMicrotasks() => Future<void>.delayed(Duration.zero);
