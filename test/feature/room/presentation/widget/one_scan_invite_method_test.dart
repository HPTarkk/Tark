import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:tark/core/l10n/app_localizations.dart';
import 'package:tark/core/widget/link_preparing_visual.dart';
import 'package:tark/core/widget/qr_widgets.dart';
import 'package:tark/feature/room/data/repository/shared_preferences_room_repository.dart';
import 'package:tark/feature/room/domain/entity/room_invite_link.dart';
import 'package:tark/feature/room/presentation/widget/one_scan_room_invite_sheet.dart';
import 'package:tark/feature/room/presentation/widget/room_invite_method_switch.dart';
import 'package:tark/feature/transfer/api/hotspot_invite_api.dart';

/// The host chooses how the other phone connects, on the code itself. The
/// code on screen is always the method the switch shows: changing it folds
/// the code back into the beacon of the new link and resolves into a new
/// code, and the scanning phone reads the method off the code it scanned.
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
    RoomInviteMethod? method,
    Future<RoomInviteLink?> Function(RoomInviteMethod)? onMethodChanged,
    VoidCallback? onShown,
    ValueNotifier<RoomInviteeProgress>? invitee,
    Locale locale = const Locale('en'),
    bool reducedMotion = false,
  }) async {
    tester.view.physicalSize = const Size(412, 915);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        locale: locale,
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context)
              .copyWith(disableAnimations: reducedMotion),
          child: child!,
        ),
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
                    method: method,
                    onMethodChanged: onMethodChanged,
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

  LinkPreparingVisual visual(WidgetTester tester) =>
      tester.widget<LinkPreparingVisual>(find.byType(LinkPreparingVisual));

  String qrData(WidgetTester tester) => tester
      .widget<GlowingQrCard>(find.byKey(const Key('one-scan-room-invite-qr')))
      .data;

  final hotspotTab = find.byKey(const Key('room-invite-method-hotspot'));
  final bluetoothTab = find.byKey(const Key('room-invite-method-bluetooth'));

  testWidgets('no opener to change the link, no switch: nothing is offered '
      'that could not be done', (tester) async {
    final rooms = await roomRepository(tester);
    await open(
      tester,
      rooms,
      link: Future.value(const HotspotInviteLink(creds)),
      method: RoomInviteMethod.hotspot,
    );
    expect(find.byType(RoomInviteMethodSwitch), findsNothing);
    await close(tester);
  });

  testWidgets('switching to Bluetooth folds the code into the Bluetooth '
      'beacon and resolves into a Bluetooth code the opener waits on', (
    tester,
  ) async {
    final rooms = await roomRepository(tester);
    final asked = <RoomInviteMethod>[];
    var shown = 0;
    final bluetooth = Completer<RoomInviteLink?>();
    await open(
      tester,
      rooms,
      link: Future.value(const HotspotInviteLink(creds)),
      method: RoomInviteMethod.hotspot,
      onShown: () => shown++,
      onMethodChanged: (method) {
        asked.add(method);
        return bluetooth.future;
      },
    );
    await tester.pump(const Duration(seconds: 1));
    expect(find.byType(RoomInviteMethodSwitch), findsOneWidget);
    expect(ScannedCode.parse(qrData(tester))?.credentials, creds);
    expect(shown, 1);
    expect(find.textContaining("doesn't share internet"), findsOneWidget);

    await tester.tap(bluetoothTab);
    await tester.pump();
    expect(asked, [RoomInviteMethod.bluetooth]);
    // The same tile, now the Bluetooth beacon; no code that would still
    // send the other phone to a hotspot on its way down.
    expect(visual(tester).kind, LinkPreparingKind.bluetooth);
    expect(visual(tester).ready, isNull);
    expect(
      find.byKey(const Key('one-scan-room-invite-preparing')),
      findsOneWidget,
    );
    await tester.pump(const Duration(milliseconds: 600));
    expect(find.textContaining('Shorter range'), findsOneWidget);

    final link = BluetoothInviteLink.fresh();
    bluetooth.complete(link);
    await settle(tester);
    await tester.pump(const Duration(seconds: 1));
    final parsed = BluetoothInviteLink.tryParse(qrData(tester));
    expect(parsed, isNotNull, reason: 'the code is the method');
    expect(parsed!.link.token, link.token);
    expect(shown, 2, reason: 'the opener waits on the new code');
    await close(tester);
  });

  testWidgets('quick taps back and forth: only the last pick lands', (
    tester,
  ) async {
    final rooms = await roomRepository(tester);
    final pending = <Completer<RoomInviteLink?>>[];
    final asked = <RoomInviteMethod>[];
    await open(
      tester,
      rooms,
      link: Future.value(const HotspotInviteLink(creds)),
      method: RoomInviteMethod.hotspot,
      onMethodChanged: (method) {
        asked.add(method);
        final next = Completer<RoomInviteLink?>();
        pending.add(next);
        return next.future;
      },
    );
    await tester.pump(const Duration(seconds: 1));

    await tester.tap(bluetoothTab);
    await tester.pump(const Duration(milliseconds: 40));
    await tester.tap(hotspotTab);
    await tester.pump(const Duration(milliseconds: 40));
    await tester.tap(bluetoothTab);
    await tester.pump(const Duration(milliseconds: 40));
    expect(asked, [
      RoomInviteMethod.bluetooth,
      RoomInviteMethod.hotspot,
      RoomInviteMethod.bluetooth,
    ]);

    // The abandoned picks answer late, and out of order.
    pending[1].complete(const HotspotInviteLink(creds));
    pending[0].complete(BluetoothInviteLink.fresh());
    await settle(tester);
    expect(find.byKey(const Key('one-scan-room-invite-qr')), findsNothing);
    expect(visual(tester).kind, LinkPreparingKind.bluetooth);

    final last = BluetoothInviteLink.fresh();
    pending[2].complete(last);
    await settle(tester);
    await tester.pump(const Duration(seconds: 1));
    expect(
      BluetoothInviteLink.tryParse(qrData(tester))!.link.token,
      last.token,
    );
    expect(tester.takeException(), isNull);
    await close(tester);
  });

  testWidgets('a method that cannot come up is told on the tile, and the '
      'other one is still a tap away', (tester) async {
    final rooms = await roomRepository(tester);
    await open(
      tester,
      rooms,
      link: Future.value(const HotspotInviteLink(creds)),
      method: RoomInviteMethod.hotspot,
      onMethodChanged: (method) async => method == RoomInviteMethod.bluetooth
          ? null
          : const HotspotInviteLink(creds),
    );
    await tester.pump(const Duration(seconds: 1));

    await tester.tap(bluetoothTab);
    await settle(tester);
    expect(
      find.byKey(const Key('one-scan-room-invite-unavailable')),
      findsOneWidget,
    );
    expect(visual(tester).failed, isTrue);
    expect(find.textContaining("couldn't start Bluetooth"), findsOneWidget);
    // The way out of a failed method is the other method, right there.
    expect(find.byType(RoomInviteMethodSwitch), findsOneWidget);

    await tester.tap(hotspotTab);
    await settle(tester);
    await tester.pump(const Duration(seconds: 1));
    expect(ScannedCode.parse(qrData(tester))?.credentials, creds);
    await close(tester);
  });

  testWidgets('once their phone is arriving the method is settled', (
    tester,
  ) async {
    final rooms = await roomRepository(tester);
    final invitee = ValueNotifier(RoomInviteeProgress.waiting);
    addTearDown(invitee.dispose);
    var asked = 0;
    await open(
      tester,
      rooms,
      link: Future.value(const HotspotInviteLink(creds)),
      method: RoomInviteMethod.hotspot,
      invitee: invitee,
      onMethodChanged: (_) async {
        asked++;
        return null;
      },
    );
    await tester.pump(const Duration(seconds: 1));
    invitee.value = RoomInviteeProgress.connecting;
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
    expect(find.byType(RoomInviteMethodSwitch), findsNothing);
    expect(asked, 0);
    await close(tester);
  });

  testWidgets('the thumb can be dragged across, in Persian from the right', (
    tester,
  ) async {
    final rooms = await roomRepository(tester);
    final asked = <RoomInviteMethod>[];
    await open(
      tester,
      rooms,
      locale: const Locale('fa'),
      link: Future.value(const HotspotInviteLink(creds)),
      method: RoomInviteMethod.hotspot,
      onMethodChanged: (method) async {
        asked.add(method);
        return BluetoothInviteLink.fresh();
      },
    );
    await tester.pump(const Duration(seconds: 1));
    // Reading start is the right edge: Hotspot sits right, Bluetooth left.
    expect(
      tester.getCenter(hotspotTab).dx,
      greaterThan(tester.getCenter(bluetoothTab).dx),
    );
    await tester.drag(hotspotTab, const Offset(-160, 0));
    await settle(tester);
    expect(asked, [RoomInviteMethod.bluetooth]);
    expect(tester.takeException(), isNull);
    await close(tester);
  });

  testWidgets('reduced motion: the switch still works and nothing loops '
      'once the code is up', (tester) async {
    final rooms = await roomRepository(tester);
    await open(
      tester,
      rooms,
      reducedMotion: true,
      link: Future.value(const HotspotInviteLink(creds)),
      method: RoomInviteMethod.hotspot,
      onMethodChanged: (_) async => BluetoothInviteLink.fresh(),
    );
    await tester.pump(const Duration(seconds: 1));
    await tester.tap(bluetoothTab);
    await settle(tester);
    await tester.pump(const Duration(seconds: 2));
    expect(BluetoothInviteLink.tryParse(qrData(tester)), isNotNull);
    expect(tester.binding.transientCallbackCount, 0);
    await close(tester);
  });
}
