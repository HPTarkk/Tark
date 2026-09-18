import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tark/core/l10n/app_localizations.dart';
import 'package:get_it/get_it.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:tark/feature/room/data/repository/shared_preferences_room_repository.dart';
import 'package:tark/feature/room/data/security/room_transport_identity_secure_store.dart';
import 'package:tark/feature/room/domain/entity/room.dart';
import 'package:tark/feature/room/domain/repository/room_repository.dart';
import 'package:tark/feature/room/presentation/manager/room_list_cubit.dart';
import 'package:tark/feature/room/presentation/page/room_list_page.dart';

/// Deleting the last saved Room played two animations back to back: the card
/// you had just deleted animated, and only then did the empty state arrive.
///
/// Two separate faults, both on the same 220ms:
///
///  * `switchOutCurve: AppMotion.easeOut` is sampled with a value that already
///    runs 1 -> 0, so it pinned the departing list near full opacity until the
///    arriving empty state had finished, then dropped it in a few frames.
///  * the `layoutBuilder` wrapped only the *outgoing* child, so at the moment
///    of the swap the widget in that Stack slot changed type, the departing
///    subtree was rebuilt from nothing, and `StaggeredEntrance` replayed its
///    entrance — the emptied list fading *in* while the switcher faded it out.
void main() {
  final getIt = GetIt.instance;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    final repository = SharedPreferencesRoomRepository();
    getIt.registerSingleton<RoomRepository>(repository);
    getIt.registerFactory<RoomListCubit>(
      () => RoomListCubit(repository, identityStore: _MemoryIdentityStore()),
    );
  });

  tearDown(() async {
    await getIt.reset();
  });

  testWidgets('deleting the last Room is one dissolve, not two', (
    tester,
  ) async {
    final repository = getIt<RoomRepository>();
    await repository.create(name: 'Weekend crew', localDisplayName: 'Me');

    await tester.pumpWidget(
      MaterialApp(
        locale: const Locale('en'),
        supportedLocales: AppLocalizations.supportedLocales,
        // The app's own delegate, not just the Material ones: these screens
        // read their copy from [AppLocalizations] now rather than switching
        // on the locale themselves, so a harness without it has no strings.
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        home: RoomListPage.buildPage(),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('rooms-list')), findsOneWidget);

    // The half of the crossfade that owns [of] — the switcher wraps each state
    // in a FadeTransition, so the nearest one above a state is its own.
    double half(Finder of) => tester
        .widget<FadeTransition>(
          find.ancestor(of: of, matching: find.byType(FadeTransition)).first,
        )
        .opacity
        .value;

    // The list's own entrance, from inside the departing subtree.
    double entrance() => tester
        .widget<FadeTransition>(
          find
              .descendant(
                of: find.byKey(const ValueKey('rooms-list-view')),
                matching: find.byType(FadeTransition),
              )
              .first,
        )
        .opacity
        .value;

    final listFinder = find.byKey(const ValueKey('rooms-list-view'));
    final emptyFinder = find.byKey(const ValueKey('rooms-empty'));

    final cubit = BlocProvider.of<RoomListCubit>(
      tester.element(find.byKey(const Key('rooms-list'))),
    );
    final saved = await repository.list(includeArchived: true);
    unawaited(cubit.deleteRoom(saved.single.room.id));
    await tester.pump();

    var frames = 0;
    while (listFinder.evaluate().isNotEmpty) {
      await tester.pump(const Duration(milliseconds: 16));
      if (listFinder.evaluate().isEmpty) break;
      expect(emptyFinder, findsOneWidget);
      frames++;

      // One dissolve: whatever the departing list gives up, the arriving empty
      // state takes. Before the fix both sat above 0.9 for most of the window.
      expect(
        half(listFinder) + half(emptyFinder),
        closeTo(1, 0.02),
        reason: 'the two halves must sum to one',
      );

      // And the list on its way out never replays its arrival.
      expect(entrance(), 1, reason: 'the departing list re-ran its entrance');
    }

    expect(frames, greaterThan(4), reason: 'the swap must not be a cut');
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('rooms-empty')), findsOneWidget);
    expect(find.byKey(const Key('rooms-create-fab')), findsNothing);
  });
}

final class _MemoryIdentityStore implements RoomTransportIdentitySecureStore {
  final Map<String, RoomTransportIdentityMaterial> _values = {};

  String _key(RoomId roomId, RoomMemberId memberId) =>
      '${roomId.value}:${memberId.value}';

  @override
  Future<void> delete({
    required RoomId roomId,
    required RoomMemberId memberId,
  }) async {
    _values.remove(_key(roomId, memberId));
  }

  @override
  Future<RoomTransportIdentityMaterial?> read({
    required RoomId roomId,
    required RoomMemberId memberId,
  }) async => _values[_key(roomId, memberId)];

  @override
  Future<void> write({
    required RoomId roomId,
    required RoomMemberId memberId,
    required RoomTransportIdentityMaterial material,
  }) async {
    _values[_key(roomId, memberId)] = material;
  }
}
