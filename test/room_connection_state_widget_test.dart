import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tark/core/l10n/app_localizations.dart';
import 'package:tark/feature/room/domain/entity/room.dart';
import 'package:tark/feature/room/presentation/widget/room_connection_status_scope.dart';
import 'package:tark/feature/room/presentation/widget/selected_room_lobby.dart';

void main() {
  SavedRoom roomWithInvite() {
    final localId = RoomMemberId('111111111111111111111111');
    final peerId = RoomMemberId('222222222222222222222222');
    final invitedId = RoomMemberId('333333333333333333333333');
    final now = DateTime.utc(2026, 9, 7, 8);
    return SavedRoom(
      room: Room(
        id: const RoomId('0123456789abcdef0123456789abcdef'),
        name: 'Morning ride',
        createdAt: now,
        updatedAt: now,
        members: [
          RoomMember(id: localId, displayName: 'Rider one', joinedAt: now),
          RoomMember(id: peerId, displayName: 'Rider two', joinedAt: now),
          RoomMember(
            id: invitedId,
            displayName: 'Open seat',
            joinedAt: now,
            pending: true,
            heldUntil: now.add(const Duration(minutes: 10)),
          ),
        ],
      ),
      membership: RoomMembership(
        localMemberId: localId,
        canManageInvites: true,
      ),
    );
  }

  Widget app({
    required Locale locale,
    required RoomConnectionUiPhase phase,
    double textScale = 1,
  }) {
    return MaterialApp(
      locale: locale,
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(
          context,
        ).copyWith(textScaler: TextScaler.linear(textScale)),
        child: child!,
      ),
      home: SelectedRoomLobby(
        room: roomWithInvite(),
        connectionPhase: phase,
        onStartRide: () {},
        onBack: () {},
      ),
    );
  }

  testWidgets(
    'English roster keeps invited seat visible without inflating joined count',
    (tester) async {
      await tester.pumpWidget(
        app(
          locale: const Locale('en'),
          phase: RoomConnectionUiPhase.readyToConnect,
        ),
      );
      await tester.pump(const Duration(milliseconds: 300));

      expect(find.text('Room members (2)'), findsOneWidget);
      expect(find.text('Rider two'), findsOneWidget);
      expect(find.text('Open seat'), findsOneWidget);
      expect(
        find.byKey(const ValueKey('room-status-readyToConnect')),
        findsOneWidget,
      );
      expect(find.byKey(const ValueKey('room-status-invited')), findsOneWidget);
      expect(find.textContaining('SSID'), findsNothing);
      expect(find.textContaining('IP'), findsNothing);
      expect(find.textContaining('Host'), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('Persian compact lobby is RTL and exposes connecting state', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(320, 640);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      app(
        locale: const Locale('fa'),
        phase: RoomConnectionUiPhase.connecting,
        textScale: 1.35,
      ),
    );
    await tester.pump(const Duration(milliseconds: 300));

    final lobby = find.byKey(const Key('selected-room-lobby'));
    expect(lobby, findsOneWidget);
    expect(Directionality.of(tester.element(lobby)), TextDirection.rtl);
    expect(find.text('اعضای اتاق (۲)'), findsOneWidget);
    expect(find.text('جای خالی'), findsOneWidget);
    expect(
      find.byKey(const ValueKey('room-status-connecting')),
      findsOneWidget,
    );
    expect(find.byKey(const ValueKey('room-status-invited')), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
