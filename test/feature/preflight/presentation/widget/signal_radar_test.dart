import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tark/core/recovery/recovery_check.dart';
import 'package:tark/feature/preflight/presentation/widget/signal_radar.dart';

RecoveryCheck _row(RecoveryStatus status) =>
    RecoveryCheck(label: 'x', detail: 'x', status: status);

Widget _wrap(Widget child) =>
    MaterialApp(home: Scaffold(body: Center(child: child)));

void main() {
  // Bounded pumps throughout, never pumpAndSettle — the sweep controller
  // repeats indefinitely while scanning, same reason as the sheet's own
  // tests (see feedback_flutter_widget_test_gotchas).

  testWidgets('still-pending checks render as dim, unresolved contacts', (
    tester,
  ) async {
    await tester.pumpWidget(
      _wrap(
        const SignalRadar(
          checks: [null, null, null, null, null, null],
          isComplete: false,
          hasBlocking: false,
          hasOnlyWarning: false,
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    // The scanning glyph shows, nothing has thrown building six dim blips
    // plus the sweep/glow layers.
    expect(find.byIcon(Icons.podcasts_rounded), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'a complete, all-clear result settles on the check glyph and stops '
    'sweeping',
    (tester) async {
      await tester.pumpWidget(
        _wrap(
          SignalRadar(
            checks: List.filled(6, _row(RecoveryStatus.ok)),
            isComplete: true,
            hasBlocking: false,
            hasOnlyWarning: false,
          ),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 800));

      expect(find.byIcon(Icons.check_rounded), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('a blocked result settles on the alert glyph', (tester) async {
    await tester.pumpWidget(
      _wrap(
        SignalRadar(
          checks: [
            _row(RecoveryStatus.bad),
            ...List.filled(5, _row(RecoveryStatus.ok)),
          ],
          isComplete: true,
          hasBlocking: true,
          hasOnlyWarning: false,
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 800));

    expect(find.byIcon(Icons.priority_high_rounded), findsOneWidget);
  });

  testWidgets('a warn-only result settles on the warning glyph', (
    tester,
  ) async {
    await tester.pumpWidget(
      _wrap(
        SignalRadar(
          checks: [
            _row(RecoveryStatus.warn),
            ...List.filled(5, _row(RecoveryStatus.ok)),
          ],
          isComplete: true,
          hasBlocking: false,
          hasOnlyWarning: true,
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 800));

    expect(find.byIcon(Icons.warning_amber_rounded), findsOneWidget);
  });

  testWidgets(
    'transitioning from scanning to resolved swaps the glyph without '
    'throwing — the sweep-stop/bloom-start handoff in didUpdateWidget',
    (tester) async {
      await tester.pumpWidget(
        _wrap(
          const SignalRadar(
            checks: [null, null, null, null, null, null],
            isComplete: false,
            hasBlocking: false,
            hasOnlyWarning: false,
          ),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 200));
      expect(find.byIcon(Icons.podcasts_rounded), findsOneWidget);

      await tester.pumpWidget(
        _wrap(
          SignalRadar(
            checks: List.filled(6, _row(RecoveryStatus.ok)),
            isComplete: true,
            hasBlocking: false,
            hasOnlyWarning: false,
          ),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 800));

      expect(find.byIcon(Icons.check_rounded), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );
}
