import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:tark/core/l10n/app_localizations.dart';
import 'package:tark/core/widget/link_preparing_visual.dart';
import 'package:tark/feature/room/data/repository/shared_preferences_room_repository.dart';
import 'package:tark/feature/room/domain/entity/room_invite_link.dart';
import 'package:tark/feature/room/presentation/widget/one_scan_room_invite_sheet.dart';
import 'package:tark/feature/transfer/api/hotspot_invite_api.dart';

/// "The error only said to close the screen and open it again." A link that
/// cannot be raised is now told on the tile itself, with a Try again that
/// does the whole preparation over in place.
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
    for (var i = 0; i < 24; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 20)),
      );
      await tester.pump(const Duration(milliseconds: 60));
    }
  }

  Future<void> open(
    WidgetTester tester,
    SharedPreferencesRoomRepository rooms, {
    required Future<RoomInviteLink?> link,
    LinkPreparingKind? kind,
    Future<RoomInviteLink?> Function()? onRetryLink,
    VoidCallback? onScanInstead,
    VoidCallback? onShown,
  }) async {
    // A phone, so the whole sheet (and its buttons) is on screen.
    tester.view.physicalSize = const Size(412, 915);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        locale: const Locale('en'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Builder(
          builder: (context) => Scaffold(
            body: Center(
              child: TextButton(
                onPressed: () => showModalBottomSheet<bool>(
                  context: context,
                  isScrollControlled: true,
                  builder: (_) => OneScanRoomInviteSheet(
                    repository: rooms,
                    link: link,
                    linkKind: kind,
                    onRetryLink: onRetryLink,
                    onScanInstead: onScanInstead,
                    onShown: onShown,
                  ),
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

  Future<void> close(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 2));
  }

  LinkPreparingVisual visual(WidgetTester tester) =>
      tester.widget<LinkPreparingVisual>(find.byType(LinkPreparingVisual));

  testWidgets('a failed link is told on the tile, with Try again asking the '
      'opener for a fresh link and morphing back into the code', (
    tester,
  ) async {
    final rooms = await roomRepository(tester);
    var asked = 0;
    var shown = 0;
    final fresh = Completer<RoomInviteLink?>();
    await open(
      tester,
      rooms,
      link: Future.value(null),
      onRetryLink: () {
        asked++;
        return fresh.future;
      },
      onShown: () => shown++,
    );

    expect(
      find.byKey(const Key('one-scan-room-invite-unavailable')),
      findsOneWidget,
    );
    expect(visual(tester).failed, isTrue);
    expect(find.textContaining("couldn't start sharing"), findsOneWidget);
    // No instructions to close and reopen: the app does it.
    expect(find.textContaining('Close this'), findsNothing);
    expect(find.byKey(const Key('one-scan-room-invite-retry')), findsOneWidget);
    expect(find.byKey(const Key('one-scan-room-invite-qr')), findsNothing);
    // The failure settles into a still frame rather than looping.
    await tester.pump(const Duration(seconds: 2));
    expect(tester.binding.transientCallbackCount, 0);

    await tester.tap(find.byKey(const Key('one-scan-room-invite-retry')));
    await tester.pump();
    expect(asked, 1);
    // Back to the beacon in the same place, saying it is trying again.
    expect(visual(tester).failed, isFalse);
    expect(
      find.byKey(const Key('one-scan-room-invite-preparing')),
      findsOneWidget,
    );
    expect(find.text('Trying again…'), findsOneWidget);

    fresh.complete(const HotspotInviteLink(creds));
    await settle(tester);
    await tester.pump(const Duration(seconds: 1));
    expect(find.byKey(const Key('one-scan-room-invite-qr')), findsOneWidget);
    expect(shown, 1, reason: 'the opener starts waiting for the scan');
    await close(tester);
  });

  testWidgets('without an opener, a failed hotspot offers no retry: the '
      'sheet never raises a link itself', (tester) async {
    final rooms = await roomRepository(tester);
    await open(tester, rooms, link: Future.value(null));

    expect(
      find.byKey(const Key('one-scan-room-invite-unavailable')),
      findsOneWidget,
    );
    expect(find.byKey(const Key('one-scan-room-invite-retry')), findsNothing);
    expect(find.byKey(const Key('one-scan-room-invite-close')), findsOneWidget);
    await close(tester);
  });

  testWidgets('a second failure is told again, and a late link from the '
      'abandoned attempt cannot land over it', (tester) async {
    final rooms = await roomRepository(tester);
    final first = Completer<RoomInviteLink?>();
    await open(
      tester,
      rooms,
      link: Future.value(null),
      onRetryLink: () => first.future,
    );
    await tester.tap(find.byKey(const Key('one-scan-room-invite-retry')));
    await tester.pump();
    first.complete(null);
    await settle(tester);

    expect(
      find.byKey(const Key('one-scan-room-invite-unavailable')),
      findsOneWidget,
    );
    expect(find.byKey(const Key('one-scan-room-invite-retry')), findsOneWidget);
    await close(tester);
  });

  testWidgets('Bluetooth without an opener offers no retry it cannot keep', (
    tester,
  ) async {
    final rooms = await roomRepository(tester);
    await open(
      tester,
      rooms,
      link: Future.value(null),
      kind: LinkPreparingKind.bluetooth,
    );

    expect(
      find.byKey(const Key('one-scan-room-invite-unavailable')),
      findsOneWidget,
    );
    expect(find.byKey(const Key('one-scan-room-invite-retry')), findsNothing);
    expect(find.byKey(const Key('one-scan-room-invite-close')), findsOneWidget);
    await close(tester);
  });

  testWidgets('"Scan their code instead" closes the sheet, then hands over', (
    tester,
  ) async {
    final rooms = await roomRepository(tester);
    var swapped = 0;
    await open(
      tester,
      rooms,
      link: Future.value(const HotspotInviteLink(creds)),
      onScanInstead: () => swapped++,
    );
    await tester.pump(const Duration(seconds: 1));
    expect(find.byKey(const Key('one-scan-room-invite-qr')), findsOneWidget);

    await tester.ensureVisible(
      find.byKey(const Key('one-scan-room-invite-scan-instead')),
    );
    await tester.tap(
      find.byKey(const Key('one-scan-room-invite-scan-instead')),
    );
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));

    expect(swapped, 1);
    expect(find.byType(OneScanRoomInviteSheet), findsNothing);
    await close(tester);
  });

  testWidgets('the swap is not offered unless the opener can act on it', (
    tester,
  ) async {
    final rooms = await roomRepository(tester);
    await open(
      tester,
      rooms,
      link: Future.value(const HotspotInviteLink(creds)),
    );
    await tester.pump(const Duration(seconds: 1));
    expect(
      find.byKey(const Key('one-scan-room-invite-scan-instead')),
      findsNothing,
    );
    await close(tester);
  });
}
