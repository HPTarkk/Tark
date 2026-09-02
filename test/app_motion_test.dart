import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tark/core/motion/app_motion.dart';

void main() {
  Widget host(Widget child, {bool reduceMotion = false}) => MaterialApp(
    home: MediaQuery(
      data: MediaQueryData(disableAnimations: reduceMotion),
      child: Scaffold(body: child),
    ),
  );

  group('StaggeredEntrance', () {
    testWidgets('items arrive in order rather than together', (tester) async {
      await tester.pumpWidget(
        host(
          StaggeredEntrance(
            children: const [Text('one'), Text('two'), Text('three')],
            builder: (context, children) => Column(children: children),
          ),
        ),
      );

      double opacityOf(String text) => tester
          .widget<FadeTransition>(
            find
                .ancestor(
                  of: find.text(text),
                  matching: find.byType(FadeTransition),
                )
                .first,
          )
          .opacity
          .value;

      // Part-way through, the first item is ahead of the last. If a refactor
      // ever gives every child the same animation this is what catches it —
      // the whole point of the stagger is that these numbers differ.
      await tester.pump(const Duration(milliseconds: 120));
      expect(opacityOf('one'), greaterThan(opacityOf('three')));

      await tester.pump(const Duration(seconds: 1));
      expect(opacityOf('one'), 1);
      expect(opacityOf('three'), 1);
    });

    testWidgets('reduced motion keeps the fade and drops the travel', (
      tester,
    ) async {
      await tester.pumpWidget(
        host(
          reduceMotion: true,
          StaggeredEntrance(
            children: const [Text('one'), Text('two')],
            builder: (context, children) => Column(children: children),
          ),
        ),
      );

      // No SlideTransition at all — not a slide of zero distance, which would
      // still cost a layer per row for nothing. Scoped to this widget's own
      // subtree: MaterialApp's route machinery brings its own transitions.
      expect(
        find.descendant(
          of: find.byType(StaggeredEntrance),
          matching: find.byType(SlideTransition),
        ),
        findsNothing,
      );
      expect(
        find.descendant(
          of: find.byType(StaggeredEntrance),
          matching: find.byType(FadeTransition),
        ),
        findsNWidgets(2),
      );

      await tester.pump(const Duration(seconds: 1));
      expect(find.text('one'), findsOneWidget);
    });

    testWidgets('a list that grows does not restart the rows already in', (
      tester,
    ) async {
      Widget build(List<String> items) => host(
        StaggeredEntrance(
          children: [for (final item in items) Text(item)],
          builder: (context, children) => Column(children: children),
        ),
      );

      await tester.pumpWidget(build(['one']));
      await tester.pump(const Duration(seconds: 1));

      await tester.pumpWidget(build(['one', 'two']));
      await tester.pump();

      final first = tester
          .widget<FadeTransition>(
            find
                .ancestor(
                  of: find.text('one'),
                  matching: find.byType(FadeTransition),
                )
                .first,
          )
          .opacity
          .value;
      expect(first, 1, reason: 'an existing row must not flash back out');
    });
  });

  group('PulseGlow', () {
    testWidgets('does not run under reduced motion', (tester) async {
      await tester.pumpWidget(
        host(
          reduceMotion: true,
          PulseGlow(
            borderRadius: BorderRadius.circular(8),
            child: const Text('cta'),
          ),
        ),
      );

      // A repeating animation is the one thing a reduced-motion user should
      // never be handed: it has no end, so there is no moment it is done. The
      // glow's DecoratedBox is the observable proof it did not run.
      expect(
        find.descendant(
          of: find.byType(PulseGlow),
          matching: find.byType(DecoratedBox),
        ),
        findsNothing,
      );
      expect(find.text('cta'), findsOneWidget);
    });

    testWidgets('disabled passes the child straight through', (tester) async {
      await tester.pumpWidget(
        host(
          PulseGlow(
            enabled: false,
            borderRadius: BorderRadius.circular(8),
            child: const Text('cta'),
          ),
        ),
      );
      expect(
        find.descendant(
          of: find.byType(PulseGlow),
          matching: find.byType(DecoratedBox),
        ),
        findsNothing,
      );
    });
  });

  group('PressableScale', () {
    testWidgets('settles under the finger and returns on release', (
      tester,
    ) async {
      await tester.pumpWidget(
        host(PressableScale(onTap: () {}, child: const Text('tap'))),
      );

      double scale() =>
          tester.widget<AnimatedScale>(find.byType(AnimatedScale)).scale;
      expect(scale(), 1);

      final gesture = await tester.startGesture(
        tester.getCenter(find.text('tap')),
      );
      await tester.pump();
      expect(scale(), lessThan(1));
      // Never to nothing: a control that vanishes under the touch reads as
      // retreating from it.
      expect(scale(), greaterThan(0.9));

      await gesture.up();
      await tester.pump();
      expect(scale(), 1);
    });

    testWidgets('a disabled control does not react', (tester) async {
      await tester.pumpWidget(host(const PressableScale(child: Text('tap'))));

      final gesture = await tester.startGesture(
        tester.getCenter(find.text('tap')),
      );
      await tester.pump();
      expect(tester.widget<AnimatedScale>(find.byType(AnimatedScale)).scale, 1);
      await gesture.up();
    });

    testWidgets('fires its callback once', (tester) async {
      var taps = 0;
      await tester.pumpWidget(
        host(PressableScale(onTap: () => taps++, child: const Text('tap'))),
      );
      await tester.tap(find.text('tap'));
      await tester.pump(const Duration(milliseconds: 200));
      expect(taps, 1);
    });
  });

  group('TapConfirmation', () {
    Widget confirming({Duration? hold}) => TapConfirmation(
      hold: hold ?? AppMotion.confirmHold,
      builder: (context, confirmed, confirm) => TextButton(
        onPressed: confirm,
        child: Text(confirmed ? 'done' : 'act'),
      ),
    );

    testWidgets('holds the confirmed state, then hands the action back', (
      tester,
    ) async {
      await tester.pumpWidget(host(confirming()));
      expect(find.text('act'), findsOneWidget);

      await tester.tap(find.text('act'));
      await tester.pump();
      expect(find.text('done'), findsOneWidget);

      // Still showing an answer a beat later — the point is that someone whose
      // eyes were on the QR code rather than the button can still catch it.
      await tester.pump(AppMotion.confirmHold ~/ 2);
      expect(find.text('done'), findsOneWidget);

      await tester.pump(AppMotion.confirmHold);
      expect(find.text('act'), findsOneWidget);
    });

    testWidgets('a second press restarts the hold rather than cutting it', (
      tester,
    ) async {
      const hold = Duration(seconds: 2);
      await tester.pumpWidget(host(confirming(hold: hold)));

      await tester.tap(find.text('act'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 1500));
      expect(find.text('done'), findsOneWidget);

      // Pressing again while confirmed must not leave a timer from the first
      // press to expire mid-way through the second confirmation.
      await tester.tap(find.text('done'));
      await tester.pump(const Duration(milliseconds: 1500));
      expect(find.text('done'), findsOneWidget);

      await tester.pump(const Duration(milliseconds: 700));
      expect(find.text('act'), findsOneWidget);
    });

    testWidgets('a pending hold does not outlive the widget', (tester) async {
      await tester.pumpWidget(host(confirming()));
      await tester.tap(find.text('act'));
      await tester.pump();

      await tester.pumpWidget(host(const SizedBox.shrink()));
      await tester.pump(AppMotion.confirmHold * 2);
      expect(tester.takeException(), isNull);
    });
  });
}
