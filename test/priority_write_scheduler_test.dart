import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:tark/feature/transfer/domain/service/priority_write_scheduler.dart';

void main() {
  group('PriorityWriteScheduler', () {
    test('high-priority writes execute in order', () async {
      final written = <int>[];
      final scheduler = PriorityWriteScheduler<int>(
        write: (p) async => written.add(p),
      );

      await scheduler.writeHighPriority(1);
      await scheduler.writeHighPriority(2);
      await scheduler.writeHighPriority(3);

      expect(written, [1, 2, 3]);
    });

    test(
      'writeHighPriority completes only after the underlying write does',
      () async {
        final gate = Future.delayed(const Duration(milliseconds: 30));
        final scheduler = PriorityWriteScheduler<int>(
          write: (p) async => gate,
        );

        var completed = false;
        final future = scheduler.writeHighPriority(1)
          ..then((_) => completed = true);
        expect(completed, isFalse);
        await future;
        expect(completed, isTrue);
      },
    );

    test('a throwing write completes the caller with the same error', () async {
      final scheduler = PriorityWriteScheduler<int>(
        write: (p) async => throw StateError('link down'),
      );

      await expectLater(
        scheduler.writeHighPriority(1),
        throwsA(isA<StateError>()),
      );
    });

    test(
      'a high-priority write queued mid-drain preempts the rest of the low-priority lane',
      () async {
        final written = <String>[];
        final unblockFirst = Completer<void>();
        var firstStarted = false;
        Future<void> write(int p) async {
          if (p == -1) {
            firstStarted = true;
            await unblockFirst.future;
          }
          written.add('${p < 0 ? 'lo' : 'hi'}$p');
        }

        final scheduler = PriorityWriteScheduler<int>(write: write);
        scheduler.writeLowPriority(-1);
        scheduler.writeLowPriority(-2);
        // Let the pump actually start the first low-priority write.
        await Future<void>.delayed(Duration.zero);
        expect(firstStarted, isTrue);

        // Queued while -1 is in flight — must run before -2, which was
        // queued earlier but hasn't started yet.
        final highDone = scheduler.writeHighPriority(1);
        unblockFirst.complete();
        await highDone;
        await Future<void>.delayed(Duration.zero);

        expect(written, ['lo-1', 'hi1', 'lo-2']);
      },
    );

    test('the low-priority lane drops the oldest write once full', () async {
      // Held open so nothing actually drains while the three writes below
      // are queued — otherwise the eager pump would drain item 1 before
      // items 2/3 are even enqueued, and the queue would never see all
      // three at once.
      final hold = Completer<void>();
      final scheduler = PriorityWriteScheduler<int>(
        write: (p) async => hold.future,
        maxQueuedLowPriority: 2,
      );

      scheduler.writeLowPriority(1); // starts writing, holds the pump open
      await Future<void>.delayed(Duration.zero);
      // Item 1 is already in flight (not in the queue any more), so these
      // two alone reach the cap without dropping anything yet.
      scheduler.writeLowPriority(2);
      scheduler.writeLowPriority(3);
      expect(scheduler.lowPriorityDrops, 0);

      scheduler.writeLowPriority(4); // over the cap — drops the oldest queued (2)
      expect(scheduler.lowPriorityDrops, 1);
      hold.complete();
    });

    test('clear() drops pending writes and fails any waiting caller', () async {
      final unblock = Completer<void>();
      final written = <int>[];
      final scheduler = PriorityWriteScheduler<int>(
        write: (p) async {
          if (p == 0) await unblock.future; // hold the pump open
          written.add(p);
        },
      );

      scheduler.writeHighPriority(0); // in flight, holds the pump
      await Future<void>.delayed(Duration.zero);
      final pending = scheduler.writeHighPriority(1); // queued, not started
      scheduler.writeLowPriority(2); // queued, not started

      scheduler.clear();
      await expectLater(pending, throwsA(isA<StateError>()));

      unblock.complete();
      await Future<void>.delayed(Duration.zero);
      // Only the in-flight write (0) went through — the cleared ones never did.
      expect(written, [0]);
    });
  });
}
