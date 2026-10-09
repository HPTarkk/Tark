import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get_it/get_it.dart';
import 'package:tark/core/entitlement/license_gate.dart';
import 'package:tark/core/entitlement/premium_feature.dart';
import 'package:tark/core/l10n/app_localizations.dart';
import 'package:tark/feature/room/domain/entity/room.dart';
import 'package:tark/feature/room/presentation/widget/selected_room_lobby.dart';
import 'package:tark/feature/transfer/api/transfer_api.dart';

void main() {
  tearDown(() => GetIt.instance.reset());
  SavedRoom room({bool localIsPreferred = true}) {
    final firstId = RoomMemberId('111111111111111111111111');
    final secondId = RoomMemberId('222222222222222222222222');
    final now = DateTime.utc(2026, 9, 5, 7);
    return SavedRoom(
      room: Room(
        id: const RoomId('0123456789abcdef0123456789abcdef'),
        name: 'Night ride',
        createdAt: now,
        updatedAt: now,
        members: [
          RoomMember(id: firstId, displayName: 'Rider one', joinedAt: now),
          RoomMember(
            id: secondId,
            displayName: 'Rider two',
            joinedAt: now.add(const Duration(seconds: 1)),
          ),
        ],
      ),
      membership: RoomMembership(
        localMemberId: localIsPreferred ? firstId : secondId,
        canManageInvites: true,
      ),
    );
  }

  Future<void> pumpLobby(
    WidgetTester tester, {
    required LiveLink? link,
    TransferMode? mode,
    SavedRoom? savedRoom,
    VoidCallback? onStartRide,
    String? failureMessage,
    VoidCallback? onRetry,
    VoidCallback? onConnect,
    VoidCallback? onUseBluetooth,
    bool requiresPremium = true,
    Locale locale = const Locale('en'),
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        locale: locale,
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: SelectedRoomLobby(
          room: savedRoom ?? room(),
          link: link,
          mode: mode,
          failureMessage: failureMessage,
          onRetry: onRetry,
          onConnect: onConnect,
          onUseBluetooth: onUseBluetooth,
          requiresPremium: requiresPremium,
          onStartRide: onStartRide ?? () {},
          onBack: () {},
        ),
      ),
    );
    await tester.pump();
  }

  testWidgets('normal lobby never exposes transport setup mechanics', (
    tester,
  ) async {
    await pumpLobby(tester, link: LiveLink.none, mode: TransferMode.wifi);

    expect(find.byKey(const Key('selected-room-start-ride')), findsOneWidget);
    expect(find.byKey(const Key('selected-room-link-callout')), findsNothing);
    expect(find.byKey(const Key('selected-room-link-chip')), findsNothing);
    expect(find.byKey(const Key('selected-room-connect')), findsNothing);
    expect(find.byKey(const Key('selected-room-connect-phones')), findsNothing);
    expect(
      find.byKey(const Key('selected-room-different-network')),
      findsNothing,
    );
    expect(
      find.byKey(const Key('selected-room-shared-network-callout')),
      findsNothing,
    );
  });

  testWidgets('Start hands the attempt to the entry whatever the link', (
    tester,
  ) async {
    for (final link in [LiveLink.none, LiveLink.wifi]) {
      for (final preferred in [true, false]) {
        var starts = 0;
        await pumpLobby(
          tester,
          link: link,
          mode: TransferMode.wifi,
          savedRoom: room(localIsPreferred: preferred),
          onStartRide: () => starts++,
        );

        // Start sits below Invite and can be under the fold.
        await tester.ensureVisible(
          find.byKey(const Key('selected-room-start-ride')),
        );
        await tester.pump();
        await tester.tap(find.byKey(const Key('selected-room-start-ride')));
        await tester.pump();

        expect(starts, 1, reason: 'link=$link preferred=$preferred');
      }
    }
  });

  testWidgets('without a link, Connect is the only recovery action', (
    tester,
  ) async {
    var retries = 0;
    var connects = 0;
    await pumpLobby(
      tester,
      link: LiveLink.none,
      mode: TransferMode.wifi,
      failureMessage: "These phones aren't linked right now.",
      onRetry: () => retries++,
      onConnect: () => connects++,
    );

    expect(
      find.byKey(const Key('selected-room-start-failure')),
      findsOneWidget,
    );
    expect(find.byKey(const Key('selected-room-retry')), findsNothing);
    expect(find.byKey(const Key('selected-room-connect-phones')), findsNothing);
    await tester.ensureVisible(
      find.byKey(const Key('selected-room-start-ride')),
    );
    await tester.tap(find.byKey(const Key('selected-room-start-ride')));
    await tester.pump();

    expect(retries, 0);
    expect(connects, 1);
  });

  testWidgets('a failure without a way to connect shows no connect action', (
    tester,
  ) async {
    await pumpLobby(
      tester,
      link: LiveLink.none,
      failureMessage: 'Wi-Fi is off. Switch it on and try again.',
      onRetry: () {},
    );

    expect(find.text('TRY AGAIN'), findsOneWidget);
    expect(find.byKey(const Key('selected-room-start-ride')), findsOneWidget);
    expect(find.byKey(const Key('selected-room-connect-phones')), findsNothing);
  });

  testWidgets(
    'locked lobby offers Premium without a stale connection error or duplicate retries',
    (tester) async {
      final gate = _Gate();
      GetIt.instance.registerSingleton<LicenseGate>(gate);
      addTearDown(gate.controller.close);
      var starts = 0;
      var retries = 0;
      var connects = 0;
      await pumpLobby(
        tester,
        link: LiveLink.none,
        mode: TransferMode.bluetooth,
        failureMessage: "These phones aren't linked right now.",
        onStartRide: () => starts++,
        onRetry: () => retries++,
        onConnect: () => connects++,
      );
      expect(find.text('Unlock Premium'), findsOneWidget);
      expect(
        find.byKey(const Key('selected-room-start-failure')),
        findsNothing,
      );
      expect(find.byKey(const Key('selected-room-retry')), findsNothing);
      expect(
        find.byKey(const Key('selected-room-connect-phones')),
        findsNothing,
      );
      await tester.tap(find.byKey(const Key('selected-room-start-ride')));
      expect(starts, 1);
      expect(retries, 0);
      expect(connects, 0);
      gate.allowed = true;
      gate.controller.add(null);
      await tester.pump();
      expect(find.text('Unlock Premium'), findsNothing);
    },
  );

  testWidgets(
    'locked two-person lobby offers a quiet, usable Bluetooth alternative',
    (tester) async {
      final gate = _Gate();
      GetIt.instance.registerSingleton<LicenseGate>(gate);
      addTearDown(gate.controller.close);
      var bluetooth = 0;
      await pumpLobby(
        tester,
        link: LiveLink.none,
        onUseBluetooth: () => bluetooth++,
      );
      expect(find.text('Unlock Premium'), findsOneWidget);
      await tester.tap(find.byKey(const Key('selected-room-free-bluetooth')));
      expect(bluetooth, 1);
    },
  );

  testWidgets('three-person room remains locked even with a Bluetooth pin', (
    tester,
  ) async {
    final gate = _Gate();
    GetIt.instance.registerSingleton<LicenseGate>(gate);
    addTearDown(gate.controller.close);
    final saved = room();
    final three = saved.copyWith(
      room: saved.room.copyWith(
        members: [
          ...saved.room.members,
          RoomMember(
            id: RoomMemberId('333333333333333333333333'),
            displayName: 'Third',
            joinedAt: DateTime.utc(2026, 10, 9),
          ),
        ],
      ),
    );
    await pumpLobby(
      tester,
      link: LiveLink.bluetooth,
      savedRoom: three,
      requiresPremium: false,
      onUseBluetooth: () {},
    );
    expect(find.text('Unlock Premium'), findsOneWidget);
    expect(find.text('Group conversations with Premium'), findsOneWidget);
    expect(find.byKey(const Key('selected-room-free-bluetooth')), findsNothing);
  });

  testWidgets('hero height settles smoothly when Premium is unlocked', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(320, 640);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final gate = _Gate();
    GetIt.instance.registerSingleton<LicenseGate>(gate);
    addTearDown(gate.controller.close);
    await pumpLobby(tester, link: LiveLink.none, locale: const Locale('fa'));
    await tester.pump(const Duration(seconds: 1));
    final hero = find.byKey(const Key('selected-room-hero'));
    final before = tester.getSize(hero).height;
    gate.allowed = true;
    gate.controller.add(null);
    await tester.pump();
    expect(tester.getSize(hero).height, closeTo(before, 0.1));
    await tester.pump(const Duration(milliseconds: 80));
    final during = tester.getSize(hero).height;
    await tester.pump(const Duration(milliseconds: 320));
    final after = tester.getSize(hero).height;
    expect(
      during,
      inInclusiveRange(
        before < after ? before : after,
        before > after ? before : after,
      ),
    );
    await tester.pump(const Duration(milliseconds: 80));
    expect(
      tester.getSize(hero).height,
      closeTo(after, 0.1),
      reason: 'removing the outgoing text must not snap the box',
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('transport state never changes the durable roster', (
    tester,
  ) async {
    await pumpLobby(tester, link: LiveLink.none);
    expect(find.text('Rider one'), findsOneWidget);
    expect(find.text('Rider two'), findsOneWidget);

    await pumpLobby(
      tester,
      link: LiveLink.bluetooth,
      mode: TransferMode.bluetooth,
    );
    expect(find.text('Rider one'), findsOneWidget);
    expect(find.text('Rider two'), findsOneWidget);
  });

  testWidgets('Persian lobby also contains no connection instructions', (
    tester,
  ) async {
    await pumpLobby(
      tester,
      link: LiveLink.none,
      mode: TransferMode.wifi,
      locale: const Locale('fa'),
    );

    expect(find.text('برقراری اتصال'), findsNothing);
    expect(find.text('هنوز وصل نیستید'), findsNothing);
    expect(find.byKey(const Key('selected-room-start-ride')), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}

class _Gate implements LicenseGate {
  bool allowed = false;
  final controller = StreamController<void>.broadcast(sync: true);
  @override
  bool allows(PremiumFeature feature) => allowed;
  @override
  bool get canPurchase => true;
  @override
  Stream<void> get changes => controller.stream;
}
