import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:tark/core/l10n/app_localizations.dart';
import 'package:tark/core/widget/sheet_shell.dart';
import 'package:tark/feature/room/data/repository/shared_preferences_room_repository.dart';
import 'package:tark/feature/room/domain/entity/room_invite_link.dart';
import 'package:tark/feature/room/presentation/widget/one_scan_room_invite_sheet.dart';
import 'package:tark/feature/transfer/api/hotspot_invite_api.dart';

/// The invite sheet after creating a Room used to sit in a narrow column
/// while the phone was getting ready, then jump out to full width when the
/// code arrived. It is one full-width panel from the first frame.
void main() {
  const creds = HotspotCredentials(
    ssid: 'AndroidShare_4410',
    passphrase: 'pass1234',
  );

  Future<SharedPreferencesRoomRepository> roomRepository(
    WidgetTester tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    final identities = <String, Object?>{};
    const channel = MethodChannel('tark/room_identity_secure_storage');
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, (
      call,
    ) async {
      final args = (call.arguments as Map).cast<String, Object?>();
      final key = '${args['roomId']}/${args['memberId']}';
      switch (call.method) {
        case 'write':
          identities[key] = args['material'];
        case 'read':
          return identities[key];
        case 'delete':
          identities.remove(key);
      }
      return null;
    });
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        channel,
        null,
      ),
    );
    final rooms = SharedPreferencesRoomRepository();
    final created = await tester.runAsync(
      () => rooms.create(name: 'Night ride', localDisplayName: 'Host'),
    );
    await tester.runAsync(() => rooms.select(created!.room.id));
    return rooms;
  }

  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 20; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 20)),
      );
      await tester.pump(const Duration(milliseconds: 50));
    }
  }

  Future<void> open(
    WidgetTester tester,
    SharedPreferencesRoomRepository rooms,
    Future<RoomInviteLink?> link,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        locale: const Locale('en'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Builder(
          builder: (context) => Scaffold(
            body: Center(
              child: TextButton(
                onPressed: () => showOneScanRoomInviteSheet(
                  context,
                  repository: rooms,
                  link: link,
                ),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await settle(tester);
  }

  double panelWidth(WidgetTester tester) => tester
      .getSize(
        find
            .descendant(
              of: find.byType(SheetShell),
              matching: find.byType(Container),
            )
            .first,
      )
      .width;

  for (final width in [360.0, 412.0, 900.0]) {
    testWidgets('the panel spans the full width at $width while preparing '
        'and once the code is up', (tester) async {
      tester.view.physicalSize = Size(width, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final rooms = await roomRepository(tester);
      final hosting = Completer<RoomInviteLink?>();
      await open(tester, rooms, hosting.future);

      expect(
        find.byKey(const Key('one-scan-room-invite-preparing')),
        findsOneWidget,
      );
      // SheetShell keeps a 12 px margin on each side.
      expect(panelWidth(tester), width - 24);

      hosting.complete(const HotspotInviteLink(creds));
      await settle(tester);
      await tester.pump(const Duration(seconds: 1));
      expect(find.byKey(const Key('one-scan-room-invite-qr')), findsOneWidget);
      expect(panelWidth(tester), width - 24);

      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(seconds: 2));
    });
  }
}
