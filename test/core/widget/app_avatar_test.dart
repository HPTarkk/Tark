import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tark/core/widget/app_avatar.dart';

void main() {
  Future<void> pump(WidgetTester tester, Widget child) => tester.pumpWidget(
    MaterialApp(
      home: Scaffold(body: Center(child: child)),
    ),
  );

  testWidgets('a known avatar draws its picture', (tester) async {
    await pump(tester, const AppAvatar(name: 'Pedi', avatarId: 5));
    final image = tester.widget<Image>(find.byType(Image));
    expect((image.image as AssetImage).assetName, 'assets/avatars/05-fox.jpg');
    expect(find.text('P'), findsNothing);
  });

  testWidgets('an avatar from a newer version gets its own face', (
    tester,
  ) async {
    await pump(tester, const AppAvatar(name: 'Pedi', avatarId: 99));
    expect(find.byKey(const ValueKey('unknown-avatar')), findsOneWidget);
    expect(find.byType(Image), findsNothing);
  });

  testWidgets('no avatar keeps the initial', (tester) async {
    await pump(tester, const AppAvatar(name: 'pedi'));
    expect(find.text('P'), findsOneWidget);
    expect(find.byType(Image), findsNothing);
  });
}
