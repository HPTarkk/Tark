import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get_it/get_it.dart';
import 'package:tark/core/entitlement/license_gate.dart';
import 'package:tark/core/entitlement/premium_feature.dart';
import 'package:tark/core/entitlement/room_access_policy.dart';
import 'package:tark/feature/room/domain/entity/room.dart';
import 'package:tark/feature/room/domain/repository/room_repository.dart';
import 'package:tark/feature/room/presentation/widget/room_group_access_guard.dart';

SavedRoom _room(int count, {bool pendingThird = false}) {
  final now = DateTime.utc(2026, 10, 9);
  final local = RoomMemberId('111111111111111111111111');
  return SavedRoom(
    room: Room(
      id: const RoomId('0123456789abcdef0123456789abcdef'),
      name: 'Group',
      createdAt: now,
      updatedAt: now,
      members: [
        for (var i = 0; i < count; i++)
          RoomMember(
            id: i == 0 ? local : RoomMemberId('${i + 1}'.padLeft(24, '0')),
            displayName: 'Person $i',
            joinedAt: now,
            pending: pendingThird && i == 2,
            heldUntil: pendingThird && i == 2
                ? now.add(const Duration(hours: 1))
                : null,
          ),
      ],
    ),
    membership: RoomMembership(localMemberId: local, canManageInvites: true),
  );
}

void main() {
  late _Gate gate;
  setUp(() {
    gate = _Gate();
    GetIt.instance.registerSingleton<LicenseGate>(gate);
  });
  tearDown(() async {
    await GetIt.instance.reset();
    await gate.controller.close();
  });

  test('a third invite requires Premium; two-person room does not', () {
    expect(RoomAccessPolicy.requiresPremium(2), isFalse);
    expect(RoomAccessPolicy.requiresPremium(3), isTrue);
    expect(RoomAccessPolicy.inviteRequiresPremium(1), isFalse);
    expect(RoomAccessPolicy.inviteRequiresPremium(2), isTrue);
  });

  for (final pendingThird in [false, true]) {
    testWidgets('free two-person session ignores held seats ($pendingThird)', (
      tester,
    ) async {
      await tester.pumpWidget(
        MaterialApp(
          home: RoomGroupAccessGuard(
            room: _room(pendingThird ? 3 : 2, pendingThird: pendingThird),
            onBlocked: (_) => fail('two confirmed members remain free'),
            builder: (_) => const Text('live audio'),
          ),
        ),
      );
      expect(find.text('live audio'), findsOneWidget);
    });
  }

  testWidgets('a free third participant never creates the live page', (
    tester,
  ) async {
    var builds = 0;
    var blocked = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: RoomGroupAccessGuard(
          room: _room(3),
          onBlocked: (_) => blocked++,
          builder: (_) {
            builds++;
            return const Text('live audio');
          },
        ),
      ),
    );
    await tester.pump();
    expect(builds, 0);
    expect(blocked, 1);
  });

  testWidgets('expiry stops a group but not a two-person session', (
    tester,
  ) async {
    gate.allowed = true;
    var blocked = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: RoomGroupAccessGuard(
          room: _room(3),
          onBlocked: (_) => blocked++,
          builder: (_) => const Text('live audio'),
        ),
      ),
    );
    expect(find.text('live audio'), findsOneWidget);
    gate.allowed = false;
    gate.controller.add(null);
    await tester.pump();
    expect(find.text('live audio'), findsNothing);
    expect(blocked, 1);
  });

  testWidgets(
    'arrival of third confirmed member blocks an ongoing free session',
    (tester) async {
      final repository = _Rooms(_room(2));
      addTearDown(repository.controller.close);
      var blocked = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: RoomGroupAccessGuard(
            room: repository.saved,
            repository: repository,
            onBlocked: (room) {
              expect(room.room.confirmedMembers, hasLength(3));
              blocked++;
            },
            builder: (_) => const Text('live audio'),
          ),
        ),
      );
      await tester.pump();
      expect(find.text('live audio'), findsOneWidget);
      repository.saved = _room(3);
      repository.controller.add(null);
      await tester.pump();
      await tester.pump();
      expect(find.text('live audio'), findsNothing);
      expect(blocked, 1);
    },
  );
}

class _Gate implements LicenseGate {
  bool allowed = false;
  final controller = StreamController<void>.broadcast(sync: true);
  @override
  bool allows(PremiumFeature feature) => allowed;
  @override
  bool get canPurchase => true;
  @override
  Stream<void> get changes => controller.stream;
}

class _Rooms implements RoomRepository {
  _Rooms(this.saved);
  SavedRoom saved;
  final controller = StreamController<void>.broadcast(sync: true);
  @override
  Stream<void> get changes => controller.stream;
  @override
  Future<SavedRoom?> get(RoomId roomId) async => saved;
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
