import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:tark/core/utils/latest_only.dart';

void main() {
  test(
    'a call started earlier but finishing later is not current once a '
    'later call has started — the exact shape of the Preflight background '
    'recheck race: a remediation action fires its own stale retry the '
    'instant Settings opens, then the user finishes there and the app '
    'resumes, starting a second, independent recheck that gets the right '
    'answer. If the stale first call happens to resolve after the fresh '
    'second one, it must not be mistaken for current.',
    () async {
      final gen = LatestOnly();
      final firstDone = Completer<void>();
      final secondDone = Completer<void>();

      Future<bool> first;
      Future<bool> second;

      first = () async {
        final token = gen.start();
        await firstDone.future; // held open past the second call starting
        return gen.isCurrent(token);
      }();

      second = () async {
        final token = gen.start();
        await secondDone.future;
        return gen.isCurrent(token);
      }();

      // Let the second call resolve (and win) first, then release the
      // first — mirroring completion order being the reverse of start
      // order.
      secondDone.complete();
      expect(await second, isTrue, reason: 'the later call is current');

      firstDone.complete();
      expect(
        await first,
        isFalse,
        reason: 'the earlier call was superseded before it resolved',
      );
    },
  );

  test('a single in-flight call is current', () async {
    final gen = LatestOnly();
    final token = gen.start();
    expect(gen.isCurrent(token), isTrue);
  });
}
