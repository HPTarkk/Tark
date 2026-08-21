import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:tark/core/utils/dispose_bag.dart';

void main() {
  group('register', () {
    test(
      'returns the resource so it can be assigned in the same expression',
      () {
        final bag = DisposeBag();
        final controller = StreamController<int>();
        addTearDown(controller.close);

        final sub = bag.register('a', controller.stream.listen((_) {}));

        expect(sub, isA<StreamSubscription<int>>());
        expect(bag.length, 1);
        sub.cancel();
      },
    );

    test(
      're-registering under the same key cancels the old resource',
      () async {
        final bag = DisposeBag();
        final controller = StreamController<int>.broadcast();
        addTearDown(controller.close);

        var firstEvents = 0;
        var secondEvents = 0;
        bag.register('a', controller.stream.listen((_) => firstEvents++));
        bag.register('a', controller.stream.listen((_) => secondEvents++));

        // The old subscription's cancel is fire-and-forget; give it a tick to
        // actually run before asserting.
        await Future<void>.delayed(Duration.zero);
        expect(bag.length, 1, reason: 'still exactly one entry under key "a"');

        controller.add(1);
        await Future<void>.delayed(Duration.zero);

        expect(
          firstEvents,
          0,
          reason: 'the replaced subscription must no longer receive events',
        );
        expect(secondEvents, 1);

        await bag.cancel('a');
      },
    );

    test('a timer re-registered under the same key cancels the old one', () {
      final bag = DisposeBag();
      var firstFired = false;
      final first = Timer(const Duration(days: 1), () => firstFired = true);
      bag.register('t', first);

      final second = Timer(const Duration(days: 1), () {});
      bag.register('t', second);

      expect(
        first.isActive,
        isFalse,
        reason: 'replaced timer must be cancelled',
      );
      expect(firstFired, isFalse);
      second.cancel();
    });
  });

  group('cancel', () {
    test('cancels and removes exactly one key, awaited', () async {
      final bag = DisposeBag();
      final timer = Timer(const Duration(days: 1), () {});
      bag.register('only', timer);

      await bag.cancel('only');

      expect(timer.isActive, isFalse);
      expect(bag.length, 0);
    });

    test('cancelling a key that was never registered is a no-op', () async {
      final bag = DisposeBag();
      await bag.cancel('nothing-here');
      expect(bag.length, 0);
    });
  });

  group('disposeAll', () {
    test('cancels every registered subscription and timer', () async {
      final bag = DisposeBag();
      final controller = StreamController<int>();
      addTearDown(controller.close);

      final sub = controller.stream.listen((_) {});
      final timerA = Timer(const Duration(days: 1), () {});
      final timerB = Timer(const Duration(days: 1), () {});
      bag.register('sub', sub);
      bag.register('timerA', timerA);
      bag.register('timerB', timerB);

      await bag.disposeAll();

      expect(timerA.isActive, isFalse);
      expect(timerB.isActive, isFalse);
      expect(bag.length, 0);
    });

    test('is idempotent — a second call finds nothing to do', () async {
      final bag = DisposeBag();
      bag.register('t', Timer(const Duration(days: 1), () {}));

      await bag.disposeAll();
      await bag.disposeAll(); // must not throw or hang

      expect(bag.length, 0);
    });

    test(
      'a fresh registration after disposeAll is not immediately cancelled',
      () async {
        final bag = DisposeBag();
        bag.register('t', Timer(const Duration(days: 1), () {}));
        await bag.disposeAll();

        final fresh = Timer(const Duration(days: 1), () {});
        bag.register('t', fresh);

        expect(fresh.isActive, isTrue);
        fresh.cancel();
      },
    );
  });
}
