import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tark/core/motion/scene_turn.dart';

class _Counter extends StatefulWidget {
  const _Counter();

  @override
  State<_Counter> createState() => _CounterState();
}

class _CounterState extends State<_Counter> {
  int count = 0;

  @override
  Widget build(BuildContext context) => TextButton(
    onPressed: () => setState(() => count++),
    child: Text('count $count'),
  );
}

Widget _host(Object scene, Widget child) => MaterialApp(
  home: Scaffold(
    body: SceneTurn(scene: scene, child: child),
  ),
);

void main() {
  testWidgets('a state keeps its own state through and after a turn', (
    tester,
  ) async {
    await tester.pumpWidget(_host('a', const _Counter()));
    await tester.tap(find.text('count 0'));
    await tester.pump();
    expect(find.text('count 1'), findsOneWidget);

    // Leaving: the same element is carried while it turns away.
    await tester.pumpWidget(_host('b', const Text('second')));
    expect(find.text('second'), findsOneWidget);
    await tester.pump(const Duration(milliseconds: 200));
    expect(find.text('count 1'), findsOneWidget);
    await tester.pump(SceneTurn.duration);
    expect(find.text('count 1'), findsNothing);

    // Arriving: a counter that turns in keeps what it counted once settled.
    await tester.pumpWidget(_host('c', const _Counter()));
    await tester.tap(find.text('count 0'), warnIfMissed: false);
    await tester.pump(SceneTurn.duration);
    await tester.pump(const Duration(milliseconds: 16));
    expect(find.text('count 1'), findsOneWidget);
    await tester.tap(find.text('count 1'));
    await tester.pump();
    expect(find.text('count 2'), findsOneWidget);
  });

  testWidgets('the same scene updates in place without turning', (
    tester,
  ) async {
    await tester.pumpWidget(_host('a', const Text('one')));
    await tester.pumpWidget(_host('a', const Text('two')));
    expect(find.text('one'), findsNothing);
    expect(find.text('two'), findsOneWidget);
    expect(tester.binding.transientCallbackCount, 0);
  });
}
