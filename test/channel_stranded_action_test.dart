import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:tark/core/router/routes.dart';
import 'package:tark/feature/room/domain/entity/room.dart';
import 'package:tark/feature/room/domain/repository/room_repository.dart';
import 'package:tark/feature/room/presentation/widget/in_room_people_action.dart';
import 'package:tark/feature/transfer/domain/entity/transfer_mode.dart';
import 'package:tark/feature/transfer/domain/service/transfer_mode_store.dart';

/// An empty channel has two causes and they need opposite offers.
///
/// Nobody has joined the room — show them the code. Or the room is full of
/// people this phone cannot hear, which no link check upstream can catch:
/// both phones are on *something*, just not the same thing. Offering a QR
/// code to someone whose friend is already in the room answers a question
/// they did not ask.
void main() {
  final localId = RoomMemberId('111111111111111111111111');
  final peerId = RoomMemberId('222222222222222222222222');
  final now = DateTime.utc(2026, 9, 3, 9);

  SavedRoom room({required bool withPeer, bool peerPending = false}) =>
      SavedRoom(
        room: Room(
          id: const RoomId('0123456789abcdef0123456789abcdef'),
          name: 'Night ride',
          createdAt: now,
          updatedAt: now,
          members: [
            RoomMember(id: localId, displayName: 'Rider one', joinedAt: now),
            if (withPeer)
              RoomMember(
                id: peerId,
                displayName: 'Rider two',
                joinedAt: now,
                pending: peerPending,
              ),
          ],
        ),
        membership: RoomMembership(
          localMemberId: localId,
          canManageInvites: true,
        ),
      );

  Future<GoRouter> pumpCard(WidgetTester tester, SavedRoom saved) async {
    final router = GoRouter(
      initialLocation: '/channel',
      routes: [
        GoRoute(
          path: '/channel',
          builder: (_, _) => Scaffold(
            body: Center(
              child: InRoomPeopleAction(
                primary: true,
                repository: _FakeRoomRepository(saved),
                modeStore: _FakeModeStore(),
              ),
            ),
          ),
        ),
        GoRoute(
          path: AppRoutes.wifiHotspotPath,
          builder: (_, _) =>
              const Scaffold(key: Key('hotspot-page'), body: SizedBox.shrink()),
        ),
      ],
    );
    addTearDown(router.dispose);
    await tester.pumpWidget(
      MaterialApp.router(locale: const Locale('en'), routerConfig: router),
    );
    // Bounded: the primary control carries a repeating pulse, so a settle
    // would wait on an animation that never ends.
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
    return router;
  }

  testWidgets('an empty room offers the code', (tester) async {
    await pumpCard(tester, room(withPeer: false));

    expect(find.byKey(const Key('channel-invite-primary')), findsOneWidget);
    expect(find.byKey(const Key('channel-connect-primary')), findsNothing);
  });

  testWidgets('a room whose members cannot be heard offers the network', (
    tester,
  ) async {
    final router = await pumpCard(tester, room(withPeer: true));

    expect(find.byKey(const Key('channel-connect-primary')), findsOneWidget);
    expect(find.byKey(const Key('channel-invite-primary')), findsNothing);
    expect(find.textContaining('not on the same network'), findsOneWidget);
    // The code is still there, quietly: "nobody can hear me" and "I want one
    // more person" are both true often enough.
    expect(find.byKey(const Key('channel-invite-quiet')), findsOneWidget);

    await tester.tap(find.byKey(const Key('channel-connect-primary')));
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));

    expect(find.byKey(const Key('hotspot-page')), findsOneWidget);
    // `go`, not `push`: the channel route is replaced, so the session and the
    // microphone come down with it exactly as they do on Leave. A pushed
    // route would have left the mic live behind this screen.
    expect(router.routerDelegate.currentConfiguration.matches.length, 1);
  });

  testWidgets('a seat nobody has claimed is not somebody who cannot hear you', (
    tester,
  ) async {
    // A held invite seat is durable and authorised, and empty. Counting it
    // would send a host who has just made a code to the bridge instead of
    // showing them the code.
    await pumpCard(tester, room(withPeer: true, peerPending: true));

    expect(find.byKey(const Key('channel-invite-primary')), findsOneWidget);
    expect(find.byKey(const Key('channel-connect-primary')), findsNothing);
  });
}

class _FakeModeStore implements TransferModeStore {
  @override
  TransferMode get mode => TransferMode.wifi;

  @override
  TransferMode? get pinnedMode => null;

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError(invocation.memberName.toString());
}

class _FakeRoomRepository implements RoomRepository {
  _FakeRoomRepository(this._room);

  final SavedRoom _room;

  @override
  Stream<void> get changes => const Stream<void>.empty();

  @override
  Future<RoomId?> selectedRoomId() async => _room.room.id;

  @override
  Future<SavedRoom?> get(RoomId id) async => id == _room.room.id ? _room : null;

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError(invocation.memberName.toString());
}
