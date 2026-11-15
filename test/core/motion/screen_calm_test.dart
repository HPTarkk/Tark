import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tark/core/motion/screen_calm.dart';
import 'package:tark/core/motion/solid_sheet_route.dart';

void main() {
  late RouteCalm calm;
  final navigator = GlobalKey<NavigatorState>();

  Future<void> pumpApp(WidgetTester tester) async {
    calm = RouteCalm();
    await tester.pumpWidget(
      MaterialApp(
        navigatorKey: navigator,
        navigatorObservers: [calm],
        home: const Scaffold(body: Text('home')),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('calm at rest; not while a page slides in or out', (
    tester,
  ) async {
    await pumpApp(tester);
    expect(calm.calm.value, isTrue);

    navigator.currentState!.push(
      MaterialPageRoute<void>(builder: (_) => const Text('next')),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    expect(calm.calm.value, isFalse, reason: 'sliding in');
    await tester.pumpAndSettle();
    expect(calm.calm.value, isTrue);

    navigator.currentState!.pop();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    expect(calm.calm.value, isFalse, reason: 'sliding out');
    await tester.pumpAndSettle();
    expect(calm.calm.value, isTrue);
  });

  testWidgets('never calm while a sheet or dialog is open', (tester) async {
    await pumpApp(tester);
    final context = navigator.currentContext!;

    showModalBottomSheet<void>(
      context: context,
      builder: (_) => const SizedBox(height: 200, child: Text('sheet')),
    );
    await tester.pumpAndSettle();
    expect(calm.calm.value, isFalse, reason: 'a sheet is up');
    navigator.currentState!.pop();
    await tester.pumpAndSettle();
    expect(calm.calm.value, isTrue);

    showDialog<void>(context: context, builder: (_) => const Text('dialog'));
    await tester.pumpAndSettle();
    expect(calm.calm.value, isFalse, reason: 'a dialog is up');
    navigator.currentState!.pop();
    await tester.pumpAndSettle();
    expect(calm.calm.value, isTrue);

    navigator.currentState!.push(
      SolidSheetRoute<void>(builder: (_) => const Text('create')),
    );
    await tester.pumpAndSettle();
    expect(calm.calm.value, isFalse, reason: 'a solid sheet is a flow');
    navigator.currentState!.pop();
    await tester.pumpAndSettle();
    expect(calm.calm.value, isTrue);
  });

  testWidgets('a replaced route counts while it arrives', (tester) async {
    await pumpApp(tester);
    navigator.currentState!.pushReplacement(
      MaterialPageRoute<void>(builder: (_) => const Text('replaced')),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    expect(calm.calm.value, isFalse);
    await tester.pumpAndSettle();
    expect(calm.calm.value, isTrue);
  });

  test('entrance holds count, and each lets go once', () {
    final before = EntranceHold.held.value;
    final a = EntranceHold.hold();
    final b = EntranceHold.hold();
    expect(EntranceHold.held.value, before + 2);
    a();
    a();
    expect(EntranceHold.held.value, before + 1);
    b();
    expect(EntranceHold.held.value, before);
  });
}
