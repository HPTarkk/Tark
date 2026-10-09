import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tark/core/l10n/app_localizations.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:tark/core/theme/app_theme.dart';
import 'package:tark/core/theme/theme_service.dart';
import 'package:get_it/get_it.dart';
import 'package:go_router/go_router.dart';
import 'package:tark/core/router/routes.dart';
import 'package:tark/feature/room/domain/entity/room.dart';
import 'package:tark/feature/room/domain/entity/room_accepted_join_snapshot.dart';
import 'package:tark/feature/room/domain/entity/room_invitation.dart';
import 'package:tark/feature/room/domain/repository/room_repository.dart';
import 'package:tark/feature/room/domain/service/room_invitation_ledger.dart';
import 'package:tark/feature/room/presentation/manager/room_list_cubit.dart';
import 'package:tark/feature/room/presentation/page/room_list_page.dart';

void main() {
  final getIt = GetIt.instance;

  setUpAll(() async {
    final fonts = FontLoader('Vazirmatn')
      ..addFont(rootBundle.load('assets/fonts/Vazirmatn-Regular.ttf'))
      ..addFont(rootBundle.load('assets/fonts/Vazirmatn-Bold.ttf'));
    await fonts.load();
    await (FontLoader(
      'MaterialIcons',
    )..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'))).load();
  });

  tearDown(() async {
    await getIt.reset();
  });

  testWidgets(
    'saved rooms stay usable at 320px and selection is durable only',
    (tester) async {
      tester.view.physicalSize = const Size(320, 640);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      final first = _savedRoom('1' * 32, 'Weekend crew', memberCount: 3);
      final second = _savedRoom('2' * 32, 'Mountain ride', memberCount: 2);
      final repository = _FakeRoomRepository(
        rooms: [first, second],
        selected: second.room.id,
      );
      getIt.registerFactory<RoomListCubit>(() => RoomListCubit(repository));

      final router = GoRouter(
        initialLocation: AppRoutes.roomsPath,
        routes: [
          GoRoute(
            path: AppRoutes.roomsPath,
            builder: (_, _) => RoomListPage.buildPage(),
          ),
          GoRoute(
            path: AppRoutes.walkiePath,
            builder: (_, _) => const Scaffold(body: Text('lobby')),
          ),
        ],
      );
      addTearDown(router.dispose);
      await tester.pumpWidget(
        MaterialApp.router(
          routerConfig: router,
          locale: const Locale('en'),
          supportedLocales: AppLocalizations.supportedLocales,
          localizationsDelegates: AppLocalizations.localizationsDelegates,
        ),
      );
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('rooms-list')), findsOneWidget);
      expect(find.text('Weekend crew'), findsOneWidget);
      expect(find.text('Mountain ride'), findsOneWidget);
      // The list offers no Start of its own: connecting happens in the lobby
      // and only there.
      expect(find.text('Start ride'), findsNothing);
      expect(tester.takeException(), isNull);

      // One tap on any card selects it and opens its lobby. Nothing connects.
      await tester.tap(find.byKey(Key('room-${first.room.id.value}')));
      await tester.pumpAndSettle();

      expect(repository.selected, first.room.id);
      expect(find.text('lobby'), findsOneWidget);
      expect(repository.transportStarts, 0);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('Persian saved rooms page is RTL at 320px', (tester) async {
    tester.view.physicalSize = const Size(320, 640);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final repository = _FakeRoomRepository(
      rooms: [_savedRoom('a' * 32, 'گروه جمعه', memberCount: 4)],
    );
    getIt.registerFactory<RoomListCubit>(() => RoomListCubit(repository));

    await tester.pumpWidget(_app(const Locale('fa'), RoomListPage.buildPage()));
    await tester.pumpAndSettle();

    expect(find.text('اتاق‌های ذخیره‌شده'), findsOneWidget);
    expect(find.text('گروه جمعه'), findsOneWidget);
    final title = tester.element(find.text('اتاق‌های ذخیره‌شده'));
    expect(Directionality.of(title), TextDirection.rtl);
    // The back arrow points right: arrow_back mirrors itself in RTL, and an
    // arrow_forward swapped in for Persian would be mirrored back to the left.
    final back = find.byKey(const Key('rooms-back'));
    expect(
      tester
          .widget<Icon>(find.descendant(of: back, matching: find.byType(Icon)))
          .icon,
      Icons.arrow_back_rounded,
    );
    expect(
      find
          .descendant(of: back, matching: find.byType(Transform))
          .evaluate()
          .any((e) => (e.widget as Transform).transform.storage[0] == -1),
      isTrue,
    );
    expect(tester.takeException(), isNull);
  });

  for (final mode in AppThemeMode.values) {
    for (final lang in ['fa', 'en']) {
      testWidgets(
        '$lang ${mode.name} room management stays separate from opening a room',
        (tester) async {
          const previewDir = String.fromEnvironment('ROOM_PREVIEW_DIR');
          final preview = previewDir.isNotEmpty;
          tester.view.physicalSize = preview
              ? const Size(390, 844)
              : const Size(320, 568);
          tester.view.devicePixelRatio = 1;
          addTearDown(tester.view.resetPhysicalSize);
          addTearDown(tester.view.resetDevicePixelRatio);
          final semantics = tester.ensureSemantics();
          SharedPreferences.setMockInitialValues({'app_theme': mode.name});
          ThemeService.initialize(await SharedPreferences.getInstance());
          await ThemeService.setMode(mode);
          final first = _savedRoom(
            'c' * 32,
            lang == 'fa' ? 'جادهٔ شمال' : 'Northbound',
            memberCount: 2,
          );
          final second = _savedRoom(
            'd' * 32,
            lang == 'fa' ? 'جمعه با رفقا' : 'Friday crew',
            memberCount: 3,
          );
          final repository = _FakeRoomRepository(
            rooms: [first, second],
            selected: second.room.id,
          );
          getIt.registerFactory<RoomListCubit>(() => RoomListCubit(repository));
          final boundary = GlobalKey();
          await tester.pumpWidget(
            MaterialApp(
              debugShowCheckedModeBanner: false,
              theme: buildAppTheme(),
              locale: Locale(lang),
              supportedLocales: AppLocalizations.supportedLocales,
              localizationsDelegates: AppLocalizations.localizationsDelegates,
              builder: (context, child) => RepaintBoundary(
                key: boundary,
                child: MediaQuery(
                  data: MediaQuery.of(context).copyWith(
                    disableAnimations: true,
                    textScaler: TextScaler.linear(preview ? 1 : 1.5),
                  ),
                  child: child!,
                ),
              ),
              home: RoomListPage.buildPage(),
            ),
          );
          await tester.pumpAndSettle();
          if (preview) {
            await _capture(
              tester,
              boundary,
              '$previewDir/rooms-${mode.name}-$lang.png',
            );
          }
          final menu = find.byKey(Key('room-menu-${first.room.id.value}'));
          expect(
            tester.getSemantics(menu).getSemanticsData().tooltip,
            contains(lang == 'fa' ? 'مدیریت' : 'Manage'),
          );
          await tester.tap(menu);
          await tester.pumpAndSettle();
          expect(find.byKey(const Key('room-actions-sheet')), findsOneWidget);
          expect(repository.selected, second.room.id);
          expect(repository.transportStarts, 0);
          for (final action in ['rename', 'archive', 'leave', 'delete']) {
            final row = find.byKey(Key('room-action-$action'));
            await tester.ensureVisible(row);
            expect(tester.getSize(row).height, greaterThanOrEqualTo(48));
          }
          expect(
            Directionality.of(
              tester.element(find.byKey(const Key('room-actions-sheet'))),
            ),
            lang == 'fa' ? TextDirection.rtl : TextDirection.ltr,
          );
          expect(tester.takeException(), isNull);
          if (preview) {
            await _capture(
              tester,
              boundary,
              '$previewDir/room-menu-${mode.name}-$lang.png',
            );
          }
          await tester.tap(find.byKey(const Key('room-actions-close')));
          await tester.pumpAndSettle();
          expect(find.byKey(const Key('room-actions-sheet')), findsNothing);
          expect(repository.selected, second.room.id);
          expect(tester.takeException(), isNull);
          await tester.pumpWidget(const SizedBox());
          semantics.dispose();
        },
      );
    }
  }
}

Future<void> _capture(WidgetTester tester, GlobalKey boundary, String path) =>
    tester.runAsync(() async {
      final render =
          boundary.currentContext!.findRenderObject()! as RenderRepaintBoundary;
      final image = await render.toImage(pixelRatio: 2);
      final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
      await File(path).writeAsBytes(bytes!.buffer.asUint8List());
      image.dispose();
    });

Widget _app(Locale locale, Widget child) => MaterialApp(
  locale: locale,
  supportedLocales: AppLocalizations.supportedLocales,
  // The app's own delegate, not just the Material ones: these screens
  // read their copy from [AppLocalizations] now rather than switching
  // on the locale themselves, so a harness without it has no strings.
  localizationsDelegates: AppLocalizations.localizationsDelegates,
  home: child,
);

SavedRoom _savedRoom(String id, String name, {required int memberCount}) {
  final now = DateTime.utc(2026, 8, 25);
  final members = List.generate(
    memberCount,
    (index) => RoomMember(
      id: RoomMemberId(
        '${id.substring(0, 20)}${index.toString().padLeft(4, '0')}',
      ),
      displayName: 'Rider ${index + 1}',
      joinedAt: now,
    ),
  );
  return SavedRoom(
    room: Room(
      id: RoomId(id),
      name: name,
      createdAt: now,
      updatedAt: now,
      members: members,
    ),
    membership: RoomMembership(
      localMemberId: members.first.id,
      canManageInvites: true,
    ),
  );
}

class _FakeRoomRepository implements RoomRepository {
  @override
  Stream<void> get changes => const Stream<void>.empty();

  _FakeRoomRepository({required List<SavedRoom> rooms, this.selected})
    : _rooms = List.of(rooms);

  final List<SavedRoom> _rooms;
  RoomId? selected;
  int transportStarts = 0;

  @override
  Future<List<SavedRoom>> list({bool includeArchived = false}) async => _rooms
      .where((saved) => includeArchived || !saved.room.archived)
      .toList(growable: false);

  @override
  Future<SavedRoom?> get(RoomId id) async {
    for (final saved in _rooms) {
      if (saved.room.id == id) return saved;
    }
    return null;
  }

  @override
  Future<SavedRoom> create({
    required String name,
    required String localDisplayName,
  }) async {
    throw UnimplementedError();
  }

  @override
  Future<SavedRoom> rename(RoomId id, String name) async {
    throw UnimplementedError();
  }

  @override
  Future<SavedRoom> setArchived(RoomId id, bool archived) async {
    throw UnimplementedError();
  }

  @override
  Future<RoomInvitation> issueInvite(
    RoomId id, {
    required RoomInvitationKind kind,
    required DateTime now,
    required Duration ttl,
    RoomTransportBootstrap? transportBootstrap,
  }) async {
    throw UnimplementedError();
  }

  @override
  Future<VerifiedRoomInvitation?> verifyAndRedeemInvite(
    RoomInvitation invite, {
    required DateTime now,
  }) async {
    throw UnimplementedError();
  }

  @override
  Future<void> revokeInvite(RoomInvitation invite) async {
    throw UnimplementedError();
  }

  @override
  Future<SavedRoom> acceptVerifiedInvite(
    VerifiedRoomInvitation verified, {
    required String displayName,
    required DateTime acceptedAt,
    bool pending = false,
    DateTime? heldUntil,
  }) async {
    throw UnimplementedError();
  }

  @override
  Future<SavedRoom> updateMember(
    RoomId id,
    RoomMemberId memberId, {
    String? displayName,
    bool? pending,
    int? avatarId,
    bool? premium,
  }) => throw UnimplementedError();

  @override
  Future<SavedRoom> removeMember(RoomId id, RoomMemberId memberId) =>
      throw UnimplementedError();

  @override
  Future<SavedRoom> importAcceptedJoin(
    RoomAcceptedJoinSnapshot snapshot, {
    required RoomMemberId localMemberId,
  }) async {
    throw UnimplementedError();
  }

  @override
  Future<SavedRoom> leave(RoomId id) async {
    throw UnimplementedError();
  }

  @override
  Future<void> delete(RoomId id) async {
    throw UnimplementedError();
  }

  @override
  Future<RoomId?> selectedRoomId() async => selected;

  @override
  Future<void> select(RoomId? id) async {
    selected = id;
  }
}
