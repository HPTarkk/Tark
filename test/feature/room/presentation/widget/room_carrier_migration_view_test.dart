import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tark/core/l10n/app_localizations.dart';
import 'package:tark/feature/room/domain/service/room_carrier_migration.dart';
import 'package:tark/feature/room/presentation/widget/room_carrier_migration_view.dart';

/// The move off the router has its own beat on screen for every step, names
/// who is doing what, never leaves the person without a way out, and opens
/// the channel only once its "connected" beat has landed.
void main() {
  Future<void> pump(
    WidgetTester tester,
    RoomMigrationProgress progress, {
    Locale locale = const Locale('en'),
    bool reduced = false,
    VoidCallback? onEstablished,
    VoidCallback? onStay,
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        locale: locale,
        supportedLocales: AppLocalizations.supportedLocales,
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        home: MediaQuery(
          data: MediaQueryData(disableAnimations: reduced),
          child: Scaffold(
            body: RoomCarrierMigrationView(
              progress: progress,
              peerName: 'Sara',
              caption: 'Night ride',
              onEstablished: onEstablished,
              onStay: onStay,
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
  }

  String title(WidgetTester tester) => tester
      .widget<Text>(find.byKey(const Key('carrier-migration-title')))
      .data!;

  testWidgets('each step says what is happening, from this phone\'s side', (
    tester,
  ) async {
    const host = RoomMigrationSide.host;
    const joiner = RoomMigrationSide.joiner;
    final expected = <RoomMigrationProgress, String>{
      const RoomMigrationProgress(RoomMigrationStep.found):
          'Found Sara on this Wi-Fi',
      const RoomMigrationProgress(RoomMigrationStep.electing):
          'Choosing whose phone leads',
      const RoomMigrationProgress(RoomMigrationStep.preparing, side: host):
          'Starting this phone\'s own Wi-Fi',
      const RoomMigrationProgress(RoomMigrationStep.preparing, side: joiner):
          'Sara\'s phone is starting its own Wi-Fi',
      const RoomMigrationProgress(RoomMigrationStep.moving, side: host):
          'Waiting for Sara to join',
      const RoomMigrationProgress(RoomMigrationStep.moving, side: joiner):
          'Joining Sara\'s phone',
      const RoomMigrationProgress(RoomMigrationStep.verifying, side: joiner):
          'Checking the new connection',
      const RoomMigrationProgress(RoomMigrationStep.established, side: host):
          'Connected directly',
    };
    for (final entry in expected.entries) {
      await pump(tester, entry.key);
      expect(title(tester), entry.value, reason: '${entry.key}');
    }
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 2));
  });

  testWidgets('the channel opens only after the established beat lands', (
    tester,
  ) async {
    var opened = 0;
    await pump(
      tester,
      const RoomMigrationProgress(
        RoomMigrationStep.verifying,
        side: RoomMigrationSide.host,
      ),
      onEstablished: () => opened++,
    );
    expect(opened, 0);
    await pump(
      tester,
      const RoomMigrationProgress(
        RoomMigrationStep.established,
        side: RoomMigrationSide.host,
      ),
      onEstablished: () => opened++,
    );
    expect(opened, 0, reason: 'the beat is still playing');
    await tester.pump(RoomCarrierMigrationView.establishedBeat);
    expect(opened, 1);
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 2));
  });

  testWidgets('a step that drags on offers staying on this Wi-Fi', (
    tester,
  ) async {
    var stayed = 0;
    await pump(
      tester,
      const RoomMigrationProgress(
        RoomMigrationStep.moving,
        side: RoomMigrationSide.joiner,
      ),
      onStay: () => stayed++,
    );
    expect(find.byKey(const Key('carrier-migration-stay')), findsNothing);
    await tester.pump(const Duration(seconds: 12));
    await tester.pump(const Duration(milliseconds: 500));
    await tester.tap(find.byKey(const Key('carrier-migration-stay')));
    expect(stayed, 1);
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 2));
  });

  testWidgets('the step rail fills as the move advances', (tester) async {
    await pump(
      tester,
      const RoomMigrationProgress(
        RoomMigrationStep.moving,
        side: RoomMigrationSide.joiner,
      ),
    );
    for (var i = 0; i < 6; i++) {
      expect(
        find.byKey(ValueKey('carrier-migration-step-$i')),
        findsOneWidget,
      );
    }
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 2));
  });

  testWidgets('Persian, right-to-left and reduced motion all render', (
    tester,
  ) async {
    await pump(
      tester,
      const RoomMigrationProgress(
        RoomMigrationStep.moving,
        side: RoomMigrationSide.host,
      ),
      locale: const Locale('fa'),
      reduced: true,
    );
    expect(title(tester), contains('Sara'));
    expect(tester.takeException(), isNull);
    // Reduced motion: nothing keeps ticking, so the tree settles.
    await tester.pumpAndSettle();
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 2));
  });
}
