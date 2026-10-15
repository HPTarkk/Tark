import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:tark/core/motion/app_motion.dart';
import 'package:tark/core/motion/backward_route.dart';
import 'package:tark/core/motion/solid_sheet_route.dart';
import 'package:tark/core/router/route_exit.dart';

/// The spatial rules at the top of app_motion.dart, pinned in both reading
/// directions: forward travels toward the reading start and arrives from the
/// reading end; back is its exact mirror, pop or not; sheets are vertical and
/// never sideways; content replaced in place hands over vertically without
/// the two halves crossing.
///
/// Every check reads where things actually are on screen mid-flight, so it
/// holds whatever the transitions are built from.
void main() {
  const width = 400.0;

  Future<void> setUp(WidgetTester tester) async {
    tester.view.physicalSize = const Size(width, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
  }

  /// Horizontal position of the page holding [label].
  double left(WidgetTester tester, String label) =>
      tester.getTopLeft(find.text(label)).dx;

  for (final rtl in [false, true]) {
    final name = rtl ? 'RTL' : 'LTR';
    // +1 when the reading end is screen-right.
    final end = rtl ? -1.0 : 1.0;

    Widget directional(Widget child) => Directionality(
      textDirection: rtl ? TextDirection.rtl : TextDirection.ltr,
      child: child,
    );

    Widget page(String label) => Scaffold(
      body: Align(
        alignment: Alignment.topLeft,
        child: Text(label, textDirection: TextDirection.ltr),
      ),
    );

    group('$name: push and pop', () {
      Future<NavigatorState> pumpApp(WidgetTester tester) async {
        await setUp(tester);
        final key = GlobalKey<NavigatorState>();
        await tester.pumpWidget(
          MaterialApp(
            navigatorKey: key,
            theme: ThemeData(
              pageTransitionsTheme: AppPageTransitionsBuilder.theme,
            ),
            builder: (context, child) => directional(child!),
            home: page('first'),
          ),
        );
        return key.currentState!;
      }

      testWidgets('forward: the new page arrives from the reading end and '
          'the old one drifts toward the reading start', (tester) async {
        final navigator = await pumpApp(tester);
        final firstAtRest = left(tester, 'first');
        navigator.push(MaterialPageRoute<void>(builder: (_) => page('second')));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 150));

        // The arriving page is still partly off the reading-end edge.
        final second = left(tester, 'second');
        expect(second * end, greaterThan(0), reason: 'arrives from the end');
        expect(
          (left(tester, 'first') - firstAtRest) * end,
          lessThan(0),
          reason: 'the old page drifts toward the reading start',
        );
        await tester.pump(const Duration(milliseconds: 150));
        expect(
          (left(tester, 'second') - second) * end,
          lessThan(0),
          reason: 'still travelling toward the reading start',
        );
        await tester.pumpAndSettle();
        expect(left(tester, 'second'), 0);
      });

      testWidgets('back: a pop sends the page back out the reading end', (
        tester,
      ) async {
        final navigator = await pumpApp(tester);
        navigator.push(MaterialPageRoute<void>(builder: (_) => page('second')));
        await tester.pumpAndSettle();

        navigator.pop();
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 120));
        final leaving = left(tester, 'second');
        expect(leaving * end, greaterThan(0), reason: 'leaves toward the end');
        await tester.pump(const Duration(milliseconds: 120));
        expect((left(tester, 'second') - leaving) * end, greaterThan(0));
        await tester.pumpAndSettle();
        expect(left(tester, 'first'), 0);
      });
    });

    group('$name: back when there is nothing to pop', () {
      testWidgets('goBackTo plays the mirror of a push, not a push', (
        tester,
      ) async {
        await setUp(tester);
        final router = GoRouter(
          initialLocation: '/channel',
          routes: [
            GoRoute(
              path: '/landing',
              pageBuilder: (context, state) => state.extra is BackwardHandoff
                  ? BackwardPage<void>(key: state.pageKey, child: page('home'))
                  : MaterialPage<void>(key: state.pageKey, child: page('home')),
            ),
            GoRoute(
              path: '/channel',
              builder: (context, state) => Builder(
                builder: (context) => Scaffold(
                  body: Align(
                    alignment: Alignment.topLeft,
                    child: TextButton(
                      onPressed: () => goBackTo(context, '/landing'),
                      child: const Text(
                        'channel',
                        textDirection: TextDirection.ltr,
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ],
        );
        await tester.pumpWidget(
          MaterialApp.router(
            theme: ThemeData(
              pageTransitionsTheme: AppPageTransitionsBuilder.theme,
            ),
            builder: (context, child) => directional(child!),
            routerConfig: router,
          ),
        );
        await tester.pumpAndSettle();
        final channelAtRest = left(tester, 'channel');

        await tester.tap(find.text('channel'));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 150));

        // Landing comes back in from the reading start...
        final home = left(tester, 'home');
        expect(home * end, lessThan(0), reason: 'returns from the start');
        // ...while the screen being left drifts toward the reading end.
        expect(
          (left(tester, 'channel') - channelAtRest) * end,
          greaterThan(0),
          reason: 'the old screen moves the way a pop moves it',
        );
        await tester.pump(const Duration(milliseconds: 150));
        expect((left(tester, 'home') - home) * end, greaterThan(0));

        await tester.pumpAndSettle();
        expect(left(tester, 'home'), 0);
        expect(find.text('channel'), findsNothing);
        expect(tester.takeException(), isNull);
      });

      testWidgets('reduced motion: back fades, nothing travels', (
        tester,
      ) async {
        await setUp(tester);
        final router = GoRouter(
          initialLocation: '/a',
          routes: [
            GoRoute(
              path: '/a',
              builder: (context, state) => Builder(
                builder: (context) => TextButton(
                  onPressed: () => goBackTo(context, '/b'),
                  child: const Text('a', textDirection: TextDirection.ltr),
                ),
              ),
            ),
            GoRoute(
              path: '/b',
              pageBuilder: (context, state) =>
                  BackwardPage<void>(key: state.pageKey, child: page('b')),
            ),
          ],
        );
        await tester.pumpWidget(
          MaterialApp.router(
            builder: (context, child) => MediaQuery(
              data: MediaQuery.of(context).copyWith(disableAnimations: true),
              child: directional(child!),
            ),
            routerConfig: router,
          ),
        );
        await tester.pumpAndSettle();
        await tester.tap(find.text('a'));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 100));
        expect(left(tester, 'b'), 0);
        await tester.pumpAndSettle();
        expect(find.text('b'), findsOneWidget);
      });
    });

    group('$name: sheets', () {
      testWidgets('a solid sheet rises from the bottom and falls back down, '
          'never sideways', (tester) async {
        await setUp(tester);
        final key = GlobalKey<NavigatorState>();
        await tester.pumpWidget(
          MaterialApp(
            navigatorKey: key,
            builder: (context, child) => directional(child!),
            home: page('below'),
          ),
        );
        key.currentState!.push(
          SolidSheetRoute<void>(builder: (_) => page('sheet')),
        );
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 120));
        final rising = tester.getTopLeft(find.text('sheet'));
        expect(rising.dy, greaterThan(0));
        expect(rising.dx, 0);
        await tester.pump(const Duration(milliseconds: 120));
        expect(tester.getTopLeft(find.text('sheet')).dy, lessThan(rising.dy));
        await tester.pumpAndSettle();
        expect(tester.getTopLeft(find.text('sheet')), Offset.zero);

        key.currentState!.pop();
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 120));
        final falling = tester.getTopLeft(find.text('sheet'));
        expect(falling.dy, greaterThan(0));
        expect(falling.dx, 0);
        await tester.pumpAndSettle();
      });
    });

    group('$name: sideways entrances follow the reading direction', () {
      testWidgets('StaggeredEntrance with a horizontal offset arrives from '
          'the reading end', (tester) async {
        await setUp(tester);
        await tester.pumpWidget(
          directional(
            Align(
              alignment: Alignment.topLeft,
              child: SizedBox(
                width: 200,
                child: StaggeredEntrance(
                  beginOffset: const Offset(1, 0),
                  builder: (context, children) => Column(
                    mainAxisSize: MainAxisSize.min,
                    children: children,
                  ),
                  children: const [
                    SizedBox(
                      width: 200,
                      height: 40,
                      child: Text('row', textDirection: TextDirection.ltr),
                    ),
                  ],
                ),
              ),
            ),
          ),
        );
        await tester.pump(const Duration(milliseconds: 60));
        expect(left(tester, 'row') * end, greaterThan(0));
        await tester.pumpAndSettle();
        expect(left(tester, 'row'), 0);
      });

      test('forwardSign points at the reading end', () {
        expect(
          AppMotion.forwardSign(rtl ? TextDirection.rtl : TextDirection.ltr),
          end,
        );
      });
    });
  }

  group('hand-over in place', () {
    Future<void> pumpSwitcher(
      WidgetTester tester,
      String label, {
      int direction = 1,
    }) => tester.pumpWidget(
      Directionality(
        textDirection: TextDirection.ltr,
        child: Align(
          alignment: Alignment.topLeft,
          child: SizedBox(
            width: 200,
            height: 100,
            child: AnimatedSwitcher(
              duration: const Duration(milliseconds: 300),
              transitionBuilder: HandOver.transition(direction: direction),
              layoutBuilder: (current, previous) => Stack(
                alignment: Alignment.topLeft,
                children: [...previous, ?current],
              ),
              child: SizedBox(
                key: ValueKey(label),
                width: 200,
                height: 100,
                child: Text(label),
              ),
            ),
          ),
        ),
      ),
    );

    double top(WidgetTester tester, String label) =>
        tester.getTopLeft(find.text(label)).dy;

    testWidgets('forward: the new rises from below, the old lifts away', (
      tester,
    ) async {
      await pumpSwitcher(tester, 'old');
      await tester.pumpAndSettle();
      await pumpSwitcher(tester, 'new');
      await tester.pump(const Duration(milliseconds: 100));
      expect(top(tester, 'new'), greaterThan(0), reason: 'rises from below');
      expect(top(tester, 'old'), lessThan(0), reason: 'never sinks into it');
      await tester.pumpAndSettle();
      expect(top(tester, 'new'), 0);
    });

    testWidgets('back: the reverse', (tester) async {
      await pumpSwitcher(tester, 'old', direction: -1);
      await tester.pumpAndSettle();
      await pumpSwitcher(tester, 'new', direction: -1);
      await tester.pump(const Duration(milliseconds: 100));
      expect(top(tester, 'new'), lessThan(0));
      expect(top(tester, 'old'), greaterThan(0));
      await tester.pumpAndSettle();
    });
  });
}
