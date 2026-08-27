import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tark/core/l10n/app_localizations.dart';
import 'package:tark/feature/room/domain/entity/room.dart';
import 'package:tark/feature/room/domain/repository/room_repository.dart';
import 'package:tark/feature/walkie/presentation/model/ride_room_identity.dart';
import 'package:tark/feature/walkie/presentation/widget/walkie_header.dart';

void main() {
  group('RideRoomIdentity', () {
    test('derives display identity only from durable Room state', () {
      final identity = RideRoomIdentity.fromSavedRoom(_savedRoom());

      expect(identity.name, 'Night Riders');
      expect(identity.code, 'ABCD-EF01');
    });

    test('resolver returns only an active selected durable Room', () async {
      final saved = _savedRoom();
      final repository = _FakeRoomRepository(
        selected: saved.room.id,
        saved: saved,
      );

      final identity = await RideRoomIdentityResolver(repository).load();

      expect(identity?.name, 'Night Riders');
      expect(identity?.code, 'ABCD-EF01');
    });

    test(
      'resolver fails closed for missing, archived or inactive Room',
      () async {
        expect(
          await RideRoomIdentityResolver(
            _FakeRoomRepository(selected: null, saved: null),
          ).load(),
          isNull,
        );

        final archived = _savedRoom(archived: true);
        expect(
          await RideRoomIdentityResolver(
            _FakeRoomRepository(selected: archived.room.id, saved: archived),
          ).load(),
          isNull,
        );

        final inactive = _savedRoom(active: false);
        expect(
          await RideRoomIdentityResolver(
            _FakeRoomRepository(selected: inactive.room.id, saved: inactive),
          ).load(),
          isNull,
        );
      },
    );
  });

  group('RideRoomIdentityBadge', () {
    testWidgets('fits 320px with large English text in light and dark themes', (
      tester,
    ) async {
      final semantics = tester.ensureSemantics();
      try {
        for (final theme in [ThemeData.light(), ThemeData.dark()]) {
          await _pumpBadge(
            tester,
            locale: const Locale('en'),
            theme: theme,
            textScale: 2,
          );
          expect(tester.takeException(), isNull);
          expect(
            find.bySemanticsLabel('Room Night Riders, code ABCD-EF01'),
            findsOneWidget,
          );
        }
      } finally {
        semantics.dispose();
      }
    });

    testWidgets('is RTL-accessible in Persian while code stays LTR', (
      tester,
    ) async {
      final semantics = tester.ensureSemantics();
      try {
        await _pumpBadge(
          tester,
          locale: const Locale('fa'),
          theme: ThemeData.dark(),
          textScale: 1.6,
        );

        expect(tester.takeException(), isNull);
        expect(
          find.bySemanticsLabel('اتاق Night Riders، کد ABCD-EF01'),
          findsOneWidget,
        );

        final code = find.text('#ABCD-EF01');
        expect(code, findsOneWidget);
        final directionality = tester.widget<Directionality>(
          find.ancestor(of: code, matching: find.byType(Directionality)).first,
        );
        expect(directionality.textDirection, TextDirection.ltr);
      } finally {
        semantics.dispose();
      }
    });
  });
}

Future<void> _pumpBadge(
  WidgetTester tester, {
  required Locale locale,
  required ThemeData theme,
  required double textScale,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      locale: locale,
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      theme: theme,
      home: Scaffold(
        body: Center(
          child: SizedBox(
            width: 320,
            child: MediaQuery(
              data: MediaQueryData(textScaler: TextScaler.linear(textScale)),
              child: RideRoomIdentityBadge(
                identity: RideRoomIdentity(
                  name: 'Night Riders',
                  code: 'ABCD-EF01',
                ),
              ),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pump();
}

SavedRoom _savedRoom({bool archived = false, bool active = true}) {
  final id = RoomId.parse('abcdef0123456789abcdef0123456789')!;
  final memberId = RoomMemberId('local-member');
  return SavedRoom(
    room: Room(
      id: id,
      name: 'Night Riders',
      createdAt: DateTime.utc(2026, 8, 27),
      updatedAt: DateTime.utc(2026, 8, 27),
      archived: archived,
      members: [
        RoomMember(
          id: memberId,
          displayName: 'Rider',
          joinedAt: DateTime.utc(2026, 8, 27),
        ),
      ],
    ),
    membership: RoomMembership(
      localMemberId: memberId,
      canManageInvites: true,
      active: active,
    ),
  );
}

final class _FakeRoomRepository implements RoomRepository {
  _FakeRoomRepository({required this.selected, required this.saved});

  final RoomId? selected;
  final SavedRoom? saved;

  @override
  Future<RoomId?> selectedRoomId() async => selected;

  @override
  Future<SavedRoom?> get(RoomId id) async =>
      saved?.room.id == id ? saved : null;

  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnsupportedError(
    'Unused RoomRepository member: ${invocation.memberName}',
  );
}
