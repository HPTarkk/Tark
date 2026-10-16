import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tark/core/widget/manual_hotspot_guide.dart';

void main() {
  Widget guide({bool reduced = false, TextDirection? direction}) => MaterialApp(
    home: MediaQuery(
      data: MediaQueryData(disableAnimations: reduced),
      child: Directionality(
        textDirection: direction ?? TextDirection.ltr,
        child: const Scaffold(
          body: ManualHotspotGuide(
            title: 'Join by hand',
            detail: 'Android said no twice.',
            steps: ['Open Wi-Fi', 'Pick Tark-AP', 'Type it', 'Come back'],
            networkLabel: 'NETWORK',
            passwordLabel: 'PASSWORD',
            copiedLabel: 'Copied',
            ssid: 'Tark-AP',
            password: 'pw-123',
          ),
        ),
      ),
    ),
  );

  testWidgets('lays out every step and the network to pick', (tester) async {
    await tester.pumpWidget(guide());
    await tester.pump(const Duration(seconds: 2));
    for (final step in ['Open Wi-Fi', 'Pick Tark-AP', 'Type it', 'Come back']) {
      expect(find.text(step), findsOneWidget);
    }
    expect(find.text('Tark-AP'), findsOneWidget);
    expect(find.text('pw-123'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('copies the password and answers with a tick', (tester) async {
    String? copied;
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'Clipboard.setData') {
          copied = (call.arguments as Map)['text'] as String?;
        }
        return null;
      },
    );
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        null,
      ),
    );
    await tester.pumpWidget(guide());
    await tester.pump(const Duration(seconds: 2));
    final copy = find.descendant(
      of: find.byKey(const Key('manual-hotspot-password')),
      matching: find.byType(IconButton),
    );
    await tester.ensureVisible(copy);
    await tester.tap(copy);
    await tester.pump(const Duration(milliseconds: 300));
    expect(copied, 'pw-123');
    expect(
      find.descendant(
        of: find.byKey(const Key('manual-hotspot-password')),
        matching: find.byIcon(Icons.check_rounded),
      ),
      findsOneWidget,
    );
    await tester.pump(const Duration(seconds: 2));
  });

  testWidgets('holds still with reduced motion, right to left too', (
    tester,
  ) async {
    await tester.pumpWidget(guide(reduced: true, direction: TextDirection.rtl));
    // Nothing is left animating: it settles at once.
    await tester.pumpAndSettle();
    expect(find.text('Come back'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
