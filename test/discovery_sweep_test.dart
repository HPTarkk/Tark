import 'package:flutter_test/flutter_test.dart';
import 'package:tark/feature/transfer/data/repository/discovery_sweep.dart';

/// Two private /24s minus our own address — what a phone holding both a
/// hotspot and a Wi-Fi address actually sweeps.
List<String> twoSubnets() => [
  for (var host = 1; host < 255; host++) '10.122.230.$host',
  for (var host = 1; host < 255; host++) '192.168.8.$host',
];

void main() {
  group('DiscoverySweep', () {
    test('never emits more than one tick\'s worth', () {
      final sweep = DiscoverySweep(probesPerTick: 48)..retarget(twoSubnets());

      // The defect this exists to prevent: >500 datagrams in one synchronous
      // burst, which overran the send buffer and silently ate the session's
      // own traffic along with the tail of the sweep.
      for (var tick = 0; tick < 40; tick++) {
        expect(sweep.nextSlice(), hasLength(48));
      }
    });

    test('covers every target within a bounded number of ticks', () {
      final targets = twoSubnets();
      final sweep = DiscoverySweep(probesPerTick: 48)..retarget(targets);

      final seen = <String>{};
      // ceil(508 / 48) == 11 ticks to cover the lot; at the 2s presence
      // cadence that is ~22s to probe two full /24s.
      for (var tick = 0; tick < 11; tick++) {
        seen.addAll(sweep.nextSlice());
      }
      expect(seen, containsAll(targets));
    });

    test('wraps around and keeps going', () {
      final sweep = DiscoverySweep(probesPerTick: 3)
        ..retarget(['a', 'b', 'c', 'd', 'e']);

      expect(sweep.nextSlice(), ['a', 'b', 'c']);
      expect(sweep.nextSlice(), ['d', 'e', 'a']);
      expect(sweep.nextSlice(), ['b', 'c', 'd']);
    });

    test('a slice is never longer than the target list', () {
      final sweep = DiscoverySweep(probesPerTick: 48)..retarget(['only']);
      expect(sweep.nextSlice(), ['only']);
      expect(sweep.nextSlice(), ['only']);
    });

    test('no targets means no probes, not a crash', () {
      final sweep = DiscoverySweep(probesPerTick: 48);
      expect(sweep.nextSlice(), isEmpty);
      sweep.retarget(const []);
      expect(sweep.nextSlice(), isEmpty);
    });

    test('reset sends the next sweep back to the head of the list', () {
      final sweep = DiscoverySweep(probesPerTick: 2)..retarget(['a', 'b', 'c']);

      expect(sweep.nextSlice(), ['a', 'b']);
      // A peer was found, so the sweep goes idle; the next one that needs it
      // should start from the top rather than mid-list.
      sweep.reset();
      expect(sweep.nextSlice(), ['a', 'b']);
    });

    test('retargeting keeps the cursor inside the new, shorter list', () {
      final sweep = DiscoverySweep(probesPerTick: 4)
        ..retarget(['a', 'b', 'c', 'd', 'e', 'f']);
      sweep.nextSlice(); // cursor at 4

      // An interface went away mid-session.
      sweep.retarget(['x', 'y']);
      expect(sweep.nextSlice(), hasLength(2));
      expect(sweep.nextSlice(), everyElement(isIn(['x', 'y'])));
    });

    test('targets are exposed read-only', () {
      final sweep = DiscoverySweep()..retarget(['a']);
      expect(() => sweep.targets.add('b'), throwsUnsupportedError);
    });
  });
}
