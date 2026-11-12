import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tark/core/widget/beacon_pulse.dart';
import 'package:tark/core/widget/segmented_track.dart';

/// The one "pick one of a few" control, and the one "working on it" mark.
void main() {
  Widget host({
    required String value,
    required ValueChanged<String> onChanged,
    TextDirection direction = TextDirection.ltr,
    bool reduced = false,
    int count = 3,
  }) => MaterialApp(
    home: Directionality(
      textDirection: direction,
      child: MediaQuery(
        data: MediaQueryData(disableAnimations: reduced),
        child: Scaffold(
          body: Center(
            child: SizedBox(
              width: 300,
              child: SegmentedTrack<String>(
                value: value,
                onChanged: onChanged,
                stacked: count > 2,
                segments: [
                  for (final name in ['a', 'b', 'c'].take(count))
                    TrackSegment(
                      segmentKey: Key('seg-$name'),
                      value: name,
                      icon: Icons.circle,
                      label: name,
                    ),
                ],
              ),
            ),
          ),
        ),
      ),
    ),
  );

  testWidgets('a tap picks, and the thumb comes to rest with nothing left '
      'ticking', (tester) async {
    var value = 'a';
    late StateSetter rebuild;
    await tester.pumpWidget(
      StatefulBuilder(
        builder: (context, setState) {
          rebuild = setState;
          return host(value: value, onChanged: (v) => rebuild(() => value = v));
        },
      ),
    );
    await tester.tap(find.byKey(const Key('seg-c')));
    await tester.pumpAndSettle();
    expect(value, 'c');
    expect(tester.binding.transientCallbackCount, 0);
  });

  testWidgets('a pick the owner turns down springs back', (tester) async {
    final asked = <String>[];
    await tester.pumpWidget(host(value: 'a', onChanged: asked.add));
    await tester.tap(find.byKey(const Key('seg-b')));
    await tester.pumpAndSettle();
    expect(asked, ['b']);
    // Still resting on the first segment: its semantics say so.
    expect(
      tester.getSemantics(find.byKey(const Key('seg-a'))),
      matchesSemantics(
        label: 'a',
        isButton: true,
        isSelected: true,
        hasSelectedState: true,
        isInMutuallyExclusiveGroup: true,
        hasTapAction: true,
      ),
    );
  });

  testWidgets('tapping the selected segment asks for nothing', (tester) async {
    final asked = <String>[];
    await tester.pumpWidget(host(value: 'b', onChanged: asked.add));
    await tester.tap(find.byKey(const Key('seg-b')));
    await tester.pumpAndSettle();
    expect(asked, isEmpty);
  });

  testWidgets('a drag picks the segment it is let go over', (tester) async {
    final asked = <String>[];
    await tester.pumpWidget(host(value: 'a', onChanged: asked.add, count: 2));
    // Slowly, so it is where the thumb is and not a fling that decides.
    final gesture = await tester.startGesture(
      tester.getCenter(find.byKey(const Key('seg-a'))),
    );
    for (var i = 0; i < 10; i++) {
      await gesture.moveBy(const Offset(12, 0));
      await tester.pump(const Duration(milliseconds: 60));
    }
    await tester.pump(const Duration(milliseconds: 300));
    await gesture.up();
    await tester.pumpAndSettle();
    expect(asked, ['b']);
  });

  testWidgets('the track follows the reading direction', (tester) async {
    await tester.pumpWidget(
      host(value: 'a', onChanged: (_) {}, direction: TextDirection.rtl),
    );
    expect(
      tester.getCenter(find.byKey(const Key('seg-a'))).dx,
      greaterThan(tester.getCenter(find.byKey(const Key('seg-c'))).dx),
    );
    // And a drag toward the reading end still means "next".
    final asked = <String>[];
    await tester.pumpWidget(
      host(
        value: 'a',
        onChanged: asked.add,
        direction: TextDirection.rtl,
        count: 2,
      ),
    );
    await tester.fling(
      find.byKey(const Key('seg-a')),
      const Offset(-120, 0),
      900,
    );
    await tester.pumpAndSettle();
    expect(asked, ['b']);
  });

  testWidgets('every segment is at least a comfortable touch target', (
    tester,
  ) async {
    await tester.pumpWidget(host(value: 'a', onChanged: (_) {}, count: 2));
    expect(
      tester.getSize(find.byKey(const Key('seg-a'))).height,
      greaterThanOrEqualTo(38),
    );
    expect(
      tester.getSize(find.byType(SegmentedTrack<String>)).height,
      greaterThanOrEqualTo(46),
    );
  });

  testWidgets('reduced motion: the thumb still arrives, in a short ease', (
    tester,
  ) async {
    var value = 'a';
    late StateSetter rebuild;
    await tester.pumpWidget(
      StatefulBuilder(
        builder: (context, setState) {
          rebuild = setState;
          return host(
            value: value,
            reduced: true,
            onChanged: (v) => rebuild(() => value = v),
          );
        },
      ),
    );
    await tester.tap(find.byKey(const Key('seg-b')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(value, 'b');
    expect(tester.binding.transientCallbackCount, 0);
  });

  group('BeaconPulse', () {
    testWidgets('takes exactly the square it is given and keeps pulsing', (
      tester,
    ) async {
      await tester.pumpWidget(
        const MaterialApp(home: Center(child: BeaconPulse(size: 18))),
      );
      expect(tester.getSize(find.byType(BeaconPulse)), const Size(18, 18));
      await tester.pump(const Duration(seconds: 1));
      expect(tester.binding.transientCallbackCount, greaterThan(0));
    });

    testWidgets('holds still under reduced motion', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: MediaQuery(
            data: MediaQueryData(disableAnimations: true),
            child: Center(child: BeaconPulse()),
          ),
        ),
      );
      await tester.pump(const Duration(seconds: 1));
      expect(tester.binding.transientCallbackCount, 0);
    });
  });
}
