import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tark/core/l10n/app_localizations.dart';
import 'package:tark/feature/room/domain/entity/room.dart';
import 'package:tark/feature/room/presentation/widget/room_connection_status_scope.dart';
import 'package:tark/feature/room/presentation/widget/room_reconnect_view.dart';
import 'package:tark/feature/room/presentation/widget/selected_room_lobby.dart';

/// The redesigned lobby and reconnect screen on the narrowest phone we
/// support, in Persian, with large text: nothing may overflow.
void main() {
  SavedRoom room(int people) {
    final now = DateTime.utc(2026, 9, 7, 8);
    return SavedRoom(
      room: Room(
        id: const RoomId('0123456789abcdef0123456789abcdef'),
        name: 'سواری طولانی صبحگاهی آخر هفته با دوستان',
        createdAt: now,
        updatedAt: now,
        members: [
          for (var i = 0; i < people; i++)
            RoomMember(
              id: RoomMemberId('${i + 1}'.padLeft(24, '0')),
              displayName: 'موتورسوار شماره ${i + 1} با نامی طولانی',
              joinedAt: now.add(Duration(seconds: i)),
            ),
        ],
      ),
      membership: RoomMembership(
        localMemberId: RoomMemberId('1'.padLeft(24, '0')),
        canManageInvites: true,
      ),
    );
  }

  Widget app(Widget home, {Locale locale = const Locale('fa')}) => MaterialApp(
    locale: locale,
    localizationsDelegates: AppLocalizations.localizationsDelegates,
    supportedLocales: AppLocalizations.supportedLocales,
    builder: (context, child) => MediaQuery(
      data: MediaQuery.of(
        context,
      ).copyWith(textScaler: const TextScaler.linear(1.35)),
      child: child!,
    ),
    home: home,
  );

  void compact(WidgetTester tester) {
    tester.view.physicalSize = const Size(320, 640);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
  }

  for (final phase in RoomConnectionUiPhase.values) {
    testWidgets('lobby with six people fits while ${phase.name}', (
      tester,
    ) async {
      compact(tester);
      await tester.pumpWidget(
        app(
          SelectedRoomLobby(
            room: room(6),
            connectionPhase: phase,
            failureMessage:
                'این گوشی‌ها الان به هم وصل نیستند. برای شروع وصلشان کنید.',
            onRetry: () {},
            onUseHomeWifi: () {},
            onStartRide: () {},
            onBack: () {},
          ),
        ),
      );
      await tester.pump(const Duration(seconds: 1));
      expect(tester.takeException(), isNull);
      // Six people push Start below the fold; it must still be reachable.
      await tester.scrollUntilVisible(
        find.byKey(const Key('selected-room-start-ride')),
        200,
      );
      expect(find.byKey(const Key('selected-room-start-ride')), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('a Room of one still offers the invite', (tester) async {
    compact(tester);
    await tester.pumpWidget(
      app(SelectedRoomLobby(room: room(1), onStartRide: () {}, onBack: () {})),
    );
    await tester.pump(const Duration(seconds: 1));
    expect(tester.takeException(), isNull);
    expect(
      find.byKey(const Key('selected-room-invite-callout')),
      findsOneWidget,
    );
    expect(find.byKey(const Key('selected-room-start-ride')), findsNothing);
  });

  for (final phase in RoomReconnectPhase.values) {
    testWidgets('code screen fits while ${phase.name}', (tester) async {
      compact(tester);
      await tester.pumpWidget(
        app(
          RoomReconnectView(
            model: RoomReconnectModel(
              side: RoomReconnectSide.show,
              peerName: 'موتورسوار با نامی بسیار طولانی',
              phase: phase,
              qrData: 'WIFI:S:DIRECT-tark;T:WPA;P:secretpass;H:false;;',
            ),
            onScan: (_) async => false,
            onSwitch: () {},
            onRetry: () {},
            onBack: () {},
          ),
        ),
      );
      await tester.pump(const Duration(seconds: 1));
      expect(tester.takeException(), isNull);
    });
  }
}
