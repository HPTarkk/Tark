import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:tark/core/l10n/app_localizations.dart';
import 'package:tark/feature/report/api/report_api.dart';
import 'package:tark/feature/report/presentation/widget/member_card_sheet.dart';
import 'package:tark/feature/room/domain/entity/room.dart';
import 'package:tark/feature/room/presentation/widget/selected_room_lobby.dart';

const _roomId = '0123456789abcdef0123456789abcdef';
const _peer = '222222222222222222222222';

SavedRoom _room() {
  const localId = RoomMemberId('111111111111111111111111');
  final now = DateTime.utc(2026, 8, 26, 18);
  return SavedRoom(
    room: Room(
      id: const RoomId(_roomId),
      name: 'Night ride',
      createdAt: now,
      updatedAt: now,
      members: [
        RoomMember(id: localId, displayName: 'Rider one', joinedAt: now),
        RoomMember(
          id: const RoomMemberId(_peer),
          displayName: 'Rider two',
          joinedAt: now,
        ),
      ],
    ),
    membership: const RoomMembership(
      localMemberId: localId,
      canManageInvites: true,
    ),
  );
}

Future<void> _pumpLobby(WidgetTester tester) async {
  await tester.pumpWidget(
    MaterialApp(
      locale: const Locale('en'),
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: SelectedRoomLobby(room: _room(), onStartRide: () {}, onBack: () {}),
    ),
  );
  // Bounded: the Start ride action pulses forever.
  await tester.pump(const Duration(seconds: 1));
}

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    ListenerMutes.instance.resetForTest();
  });
  tearDown(ListenerMutes.instance.resetForTest);

  testWidgets('tapping another member opens their card with Report', (
    tester,
  ) async {
    await _pumpLobby(tester);
    await tester.tap(find.text('Rider two'));
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));

    expect(find.byType(MemberCardSheet), findsOneWidget);
    expect(find.text('Report'), findsOneWidget);

    await tester.tap(find.byKey(const Key('member-card-mute')));
    await tester.pump(const Duration(milliseconds: 500));
    expect(ListenerMutes.instance.isMemberMuted(_roomId, _peer), isTrue);
  });

  testWidgets('your own row is not a profile you can report', (tester) async {
    await _pumpLobby(tester);
    await tester.tap(find.text('Rider one'), warnIfMissed: false);
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
    expect(find.byType(MemberCardSheet), findsNothing);
  });

  testWidgets('a muted member shows it on their lobby row', (tester) async {
    await ListenerMutes.instance.setMemberMuted(_roomId, _peer, true);
    await _pumpLobby(tester);
    expect(find.byIcon(Icons.volume_off_rounded), findsOneWidget);
  });
}
