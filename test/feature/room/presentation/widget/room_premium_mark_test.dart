import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tark/core/l10n/app_localizations.dart';
import 'package:tark/feature/room/domain/entity/room.dart';
import 'package:tark/feature/room/presentation/widget/room_visuals.dart';
import 'package:tark/feature/room/presentation/widget/selected_room_lobby.dart';

/// Subscribed members carry a premium mark on their face in the lobby; others
/// do not, and the overlapping face stack never shows one.
void main() {
  final now = DateTime.utc(2026, 10, 3, 18);
  final localId = RoomMemberId('111111111111111111111111');
  final peerId = RoomMemberId('222222222222222222222222');

  SavedRoom room({required bool peerPremium}) => SavedRoom(
    room: Room(
      id: const RoomId('0123456789abcdef0123456789abcdef'),
      name: 'Night ride',
      createdAt: now,
      updatedAt: now,
      members: [
        RoomMember(id: localId, displayName: 'Rider one', joinedAt: now),
        RoomMember(
          id: peerId,
          displayName: 'Rider two',
          joinedAt: now,
          premium: peerPremium,
        ),
      ],
    ),
    membership: RoomMembership(localMemberId: localId, canManageInvites: true),
  );

  Widget app(Widget home) => MaterialApp(
    localizationsDelegates: AppLocalizations.localizationsDelegates,
    supportedLocales: AppLocalizations.supportedLocales,
    home: home,
  );

  /// Opacity of each premium mark on screen, in build order.
  List<double> marks(WidgetTester tester) => tester
      .widgetList<PremiumMark>(find.byType(PremiumMark))
      .map(
        (mark) => tester
            .widget<AnimatedOpacity>(
              find.descendant(
                of: find.byWidget(mark),
                matching: find.byType(AnimatedOpacity),
              ),
            )
            .opacity,
      )
      .toList();

  testWidgets('the lobby marks the premium member and only them', (
    tester,
  ) async {
    await tester.pumpWidget(
      app(
        SelectedRoomLobby(
          room: room(peerPremium: true),
          onStartRide: () {},
          onBack: () {},
        ),
      ),
    );
    await tester.pump(const Duration(seconds: 1));

    // One shown: the premium rider's row. The face stack at the top never
    // shows marks, and the local rider is not premium.
    expect(marks(tester).where((o) => o == 1), hasLength(1));
    expect(find.bySemanticsLabel(RegExp('PREMIUM')), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a face stack shows no marks', (tester) async {
    await tester.pumpWidget(
      app(
        Scaffold(
          body: RoomFaces(members: room(peerPremium: true).room.members),
        ),
      ),
    );
    expect(marks(tester), everyElement(0));
  });

  testWidgets('the mark grows in when it turns up', (tester) async {
    Widget face(bool premium) => app(
      Center(
        child: TintedAvatar(seed: 'a', name: 'A', premium: premium),
      ),
    );
    await tester.pumpWidget(face(false));
    await tester.pumpWidget(face(true));
    await tester.pump(const Duration(milliseconds: 40));
    final scale = tester.widget<AnimatedScale>(find.byType(AnimatedScale));
    expect(scale.scale, 1);
    final mid = tester.getSize(find.byKey(const ValueKey('premium-mark')));
    await tester.pumpAndSettle();
    final end = tester.getSize(find.byKey(const ValueKey('premium-mark')));
    expect(end.width, greaterThan(0));
    expect(mid, end, reason: 'layout size is fixed; only paint scales');
  });
}
