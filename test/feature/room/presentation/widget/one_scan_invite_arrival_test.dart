import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:tark/core/l10n/app_localizations.dart';
import 'package:tark/core/widget/connection_journey.dart';
import 'package:tark/core/widget/link_preparing_visual.dart';
import 'package:tark/core/widget/qr_widgets.dart';
import 'package:tark/feature/room/data/repository/shared_preferences_room_repository.dart';
import 'package:tark/feature/room/domain/entity/room_invite_link.dart';
import 'package:tark/feature/room/presentation/widget/one_scan_room_invite_sheet.dart';
import 'package:tark/feature/transfer/api/hotspot_invite_api.dart';

/// "Notify the host when a joiner starts connecting": the code folds into the
/// two phones finding each other the moment this phone's link sees the other
/// phone, tied to what the link actually sees — and if that try falls
/// through, the code is back, still good.
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
    ValueListenable<RoomInviteeProgress>? invitee,
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
                    invitee: invitee,
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

  final qr = find.byKey(const Key('one-scan-room-invite-qr'));
  final journey = find.byKey(const Key('one-scan-room-invite-journey'));

  JourneyStage stage(WidgetTester tester) =>
      tester.widget<ConnectionJourney>(journey).stage;

  testWidgets('the code folds into the arrival the moment the other phone is '
      'heard, and lands connected', (tester) async {
    final rooms = await roomRepository(tester);
    final invitee = ValueNotifier(RoomInviteeProgress.waiting);
    await open(
      tester,
      rooms,
      link: Future.value(const HotspotInviteLink(creds)),
      invitee: invitee,
    );
    expect(qr, findsOneWidget);
    expect(journey, findsNothing);

    invitee.value = RoomInviteeProgress.connecting;
    await tester.pump();
    expect(journey, findsOneWidget);
    // The read beat first: the code's brackets fold into the link.
    expect(stage(tester), JourneyStage.scanned);
    expect(find.text("They're connecting…"), findsOneWidget);
    await tester.pump();
    expect(stage(tester), JourneyStage.linking);
    await tester.pump(const Duration(seconds: 1));
    expect(qr, findsNothing);
    expect(find.byKey(const Key('one-scan-room-invite-done')), findsNothing);

    invitee.value = RoomInviteeProgress.connected;
    await tester.pump();
    expect(stage(tester), JourneyStage.established);
    await tester.pump(const Duration(seconds: 1));
    expect(find.text('Connected'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await close(tester);
  });

  testWidgets('a try that falls through brings the same code back, with a '
      'word that it did not go through', (tester) async {
    final rooms = await roomRepository(tester);
    final invitee = ValueNotifier(RoomInviteeProgress.waiting);
    await open(
      tester,
      rooms,
      link: Future.value(const HotspotInviteLink(creds)),
      invitee: invitee,
    );
    final before = tester
        .widget<GlowingQrCard>(find.byType(GlowingQrCard))
        .data;

    invitee.value = RoomInviteeProgress.connecting;
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
    expect(qr, findsNothing);

    invitee.value = RoomInviteeProgress.waiting;
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
    expect(qr, findsOneWidget);
    expect(
      tester.widget<GlowingQrCard>(find.byType(GlowingQrCard)).data,
      before,
      reason: 'the code on screen is the one they already have',
    );
    expect(
      find.byKey(const ValueKey('one-scan-room-invite-lost')),
      findsOneWidget,
    );

    // The next arrival clears the note.
    invitee.value = RoomInviteeProgress.connecting;
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
    invitee.value = RoomInviteeProgress.waiting;
    await tester.pump();
    expect(tester.takeException(), isNull);
    await close(tester);
  });

  testWidgets('nothing arrives before there is a code to arrive by', (
    tester,
  ) async {
    final rooms = await roomRepository(tester);
    final invitee = ValueNotifier(RoomInviteeProgress.connecting);
    final link = Completer<RoomInviteLink?>();
    await open(tester, rooms, link: link.future, invitee: invitee);
    expect(journey, findsNothing);
    expect(
      find.byKey(const Key('one-scan-room-invite-preparing')),
      findsOneWidget,
    );
    link.complete(const HotspotInviteLink(creds));
    await settle(tester);
    expect(journey, findsOneWidget);
    await close(tester);
  });

  testWidgets('Bluetooth arrivals are drawn as Bluetooth', (tester) async {
    final rooms = await roomRepository(tester);
    final invitee = ValueNotifier(RoomInviteeProgress.waiting);
    await open(
      tester,
      rooms,
      link: Future.value(const HotspotInviteLink(creds)),
      kind: LinkPreparingKind.bluetooth,
      invitee: invitee,
    );
    invitee.value = RoomInviteeProgress.connecting;
    await tester.pump();
    expect(
      tester.widget<ConnectionJourney>(journey).link,
      JourneyLink.bluetooth,
    );
    await close(tester);
  });
}
