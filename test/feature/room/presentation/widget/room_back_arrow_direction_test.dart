import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tark/core/l10n/app_localizations.dart';
import 'package:tark/feature/room/domain/entity/room.dart';
import 'package:tark/feature/room/presentation/widget/room_reconnect_view.dart';
import 'package:tark/feature/room/presentation/widget/selected_room_lobby.dart';

/// The back arrow must point the way back in both reading directions.
///
/// `Icons.arrow_back_rounded` mirrors itself in right-to-left, so it already
/// points right in Persian. Swapping in `arrow_forward` for RTL — which these
/// screens used to do — gets mirrored as well, and lands pointing left.
void main() {
  final now = DateTime.utc(2026, 9, 7, 8);
  final room = SavedRoom(
    room: Room(
      id: const RoomId('0123456789abcdef0123456789abcdef'),
      name: 'Weekend crew',
      createdAt: now,
      updatedAt: now,
      members: [
        RoomMember(
          id: RoomMemberId('1'.padLeft(24, '0')),
          displayName: 'Sara',
          joinedAt: now,
        ),
      ],
    ),
    membership: RoomMembership(
      localMemberId: RoomMemberId('1'.padLeft(24, '0')),
      canManageInvites: true,
    ),
  );

  Widget app(Widget home, Locale locale) => MaterialApp(
    locale: locale,
    localizationsDelegates: AppLocalizations.localizationsDelegates,
    supportedLocales: AppLocalizations.supportedLocales,
    home: home,
  );

  final screens = <String, (Key, Widget Function())>{
    'lobby': (
      const Key('selected-room-lobby-back'),
      () => SelectedRoomLobby(room: room, onStartRide: () {}, onBack: () {}),
    ),
    'reconnect screen': (
      const Key('room-reconnect-back'),
      () => RoomReconnectView(
        model: const RoomReconnectModel(
          side: RoomReconnectSide.show,
          peerName: 'Sara',
          qrData: 'WIFI:S:DIRECT-tark;T:WPA;P:secretpass;H:false;;',
        ),
        onScan: (_) async => false,
        onSwitch: () {},
        onRetry: () {},
        onBack: () {},
      ),
    ),
  };

  for (final MapEntry(key: name, value: (backKey, build)) in screens.entries) {
    for (final (locale, rtl) in [
      (const Locale('en'), false),
      (const Locale('fa'), true),
    ]) {
      testWidgets('$name back arrow points back in ${locale.languageCode}', (
        tester,
      ) async {
        await tester.pumpWidget(app(build(), locale));
        await tester.pump(const Duration(seconds: 1));
        expectPointsBack(tester, find.byKey(backKey), rtl: rtl);
      });
    }
  }
}

/// Back arrow, mirrored exactly when the layout is right-to-left.
void expectPointsBack(WidgetTester tester, Finder button, {required bool rtl}) {
  final icon = tester.widget<Icon>(
    find.descendant(of: button, matching: find.byType(Icon)),
  );
  expect(icon.icon, Icons.arrow_back_rounded);
  final mirrored = find
      .descendant(of: button, matching: find.byType(Transform))
      .evaluate()
      .any((e) => (e.widget as Transform).transform.storage[0] == -1);
  expect(mirrored, rtl, reason: 'mirrored in RTL only');
}
