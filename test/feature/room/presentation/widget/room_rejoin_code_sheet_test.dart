import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tark/core/l10n/app_localizations.dart';
import 'package:tark/core/widget/sheet_shell.dart';
import 'package:tark/feature/room/domain/entity/room.dart';
import 'package:tark/feature/room/presentation/widget/room_rejoin_help.dart';

void main() {
  testWidgets(
    'the code sheet keeps its width and slides away when they are back',
    (tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final back = ValueNotifier(false);
      addTearDown(back.dispose);
      late BuildContext host;
      await tester.pumpWidget(
        MaterialApp(
          locale: const Locale('en'),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Builder(
            builder: (context) {
              host = context;
              return const Scaffold();
            },
          ),
        ),
      );
      showRoomRejoinCodeSheet(host, room: _room(), name: 'Sara', back: back);
      await tester.pumpAndSettle();
      final shell = find.byType(SheetShell);
      final before = tester.getSize(shell).width;

      back.value = true;
      await tester.pump();
      for (var i = 0; i < 6; i++) {
        await tester.pump(const Duration(milliseconds: 60));
        expect(tester.getSize(shell).width, before);
      }
      await tester.pump(const Duration(milliseconds: 600));
      expect(find.text('Sara is back'), findsOneWidget);
      expect(tester.getSize(shell).width, before);

      // The hold ends, then the sheet slides down rather than vanishing.
      await tester.pump(const Duration(milliseconds: 700));
      await tester.pump(const Duration(milliseconds: 100));
      expect(shell, findsOneWidget);
      await tester.pumpAndSettle();
      expect(shell, findsNothing);
    },
  );
}

SavedRoom _room() {
  final at = DateTime.utc(2026, 10, 3);
  const local = RoomMemberId('local');
  return SavedRoom(
    room: Room(
      id: const RoomId('0123456789abcdef0123456789abcdef'),
      name: 'Ride',
      createdAt: at,
      updatedAt: at,
      members: [
        RoomMember(id: local, displayName: 'Ali', joinedAt: at),
        RoomMember(
          id: const RoomMemberId('sara'),
          displayName: 'Sara',
          joinedAt: at,
        ),
      ],
    ),
    membership: const RoomMembership(
      localMemberId: local,
      canManageInvites: true,
    ),
  );
}
