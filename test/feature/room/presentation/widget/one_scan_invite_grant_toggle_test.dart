import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:tark/core/l10n/app_localizations.dart';
import 'package:tark/core/widget/qr_widgets.dart';
import 'package:tark/feature/room/data/repository/shared_preferences_room_repository.dart';
import 'package:tark/feature/room/data/security/room_transport_identity_lifecycle.dart';
import 'package:tark/feature/room/data/security/room_transport_identity_secure_store.dart';
import 'package:tark/feature/room/domain/entity/room.dart';
import 'package:tark/feature/room/domain/entity/room_direct_join_bundle.dart';
import 'package:tark/feature/room/domain/service/room_member_transport_identity.dart';
import 'package:tark/feature/room/presentation/widget/one_scan_room_invite_sheet.dart';

/// ITEM 10: the inviter decides, on the code itself, whether the person who
/// scans it may invite others — and the code on screen always says exactly
/// what was decided, signed.
void main() {
  late SharedPreferencesRoomRepository repository;
  late _MemoryStore store;
  late RoomTransportIdentityLifecycle identity;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    repository = SharedPreferencesRoomRepository();
    store = _MemoryStore();
    identity = RoomTransportIdentityLifecycle(store: store);
  });

  Widget app(Widget child, {Locale locale = const Locale('en')}) => MaterialApp(
    locale: locale,
    supportedLocales: AppLocalizations.supportedLocales,
    localizationsDelegates: AppLocalizations.localizationsDelegates,
    home: Scaffold(body: child),
  );

  /// Crypto and storage are real futures; let them run, then draw.
  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 6; i += 1) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 20)),
      );
      await tester.pump(const Duration(milliseconds: 400));
    }
  }

  RoomDirectJoinBundle shownBundle(WidgetTester tester) {
    final qr = tester.widget<GlowingQrCard>(
      find.byKey(const Key('one-scan-room-invite-qr')),
    );
    return RoomDirectJoinBundle.decode(qr.data);
  }

  Future<bool> grantVerifies(RoomDirectJoinBundle bundle, List<int> root) =>
      RoomMemberTransportIdentityCrypto().verifyCertificate(
        certificate: bundle.certificate,
        expectedIssuerPublicKey: root,
      );

  testWidgets('the creator\'s code grants by default, and one tap revokes it', (
    tester,
  ) async {
    late SavedRoom room;
    late List<int> root;
    await tester.runAsync(() async {
      room = await repository.create(
        name: 'Night ride',
        localDisplayName: 'Host',
      );
      await repository.select(room.room.id);
      root = (await identity.ensureLocalIdentity(
        room,
      )).certificate.rootIssuerPublicKey;
    });

    await tester.pumpWidget(
      app(
        OneScanRoomInviteSheet(
          repository: repository,
          identityLifecycle: identity,
        ),
      ),
    );
    await settle(tester);

    final toggle = find.byKey(const Key('room-invite-grant-toggle'));
    expect(toggle, findsOneWidget);
    expect(find.text('Let them invite people'), findsOneWidget);
    expect(
      find.text('They can bring their own friends in too.'),
      findsOneWidget,
    );
    expect(tester.widget<Switch>(find.byType(Switch)).value, isTrue);

    final granted = shownBundle(tester);
    expect(granted.certificate.canInvite, isTrue);
    expect(granted.snapshot.grantsInviteManagement, isTrue);
    expect(await tester.runAsync(() => grantVerifies(granted, root)), isTrue);
    final seatsBefore = (await tester.runAsync(
      () => repository.get(room.room.id),
    ))!.room.members.length;

    await tester.tap(toggle);
    await settle(tester);

    expect(tester.widget<Switch>(find.byType(Switch)).value, isFalse);
    expect(find.text("They join, but can't add anyone else."), findsOneWidget);
    final denied = shownBundle(tester);
    expect(denied.certificate.canInvite, isFalse);
    expect(denied.snapshot.grantsInviteManagement, isFalse);
    // Same seat, same person: only the signature changed.
    expect(denied.memberId, granted.memberId);
    expect(denied.memberKeyPair.publicKey, granted.memberKeyPair.publicKey);
    expect(
      (await tester.runAsync(
        () => repository.get(room.room.id),
      ))!.room.members.length,
      seatsBefore,
    );
    expect(await tester.runAsync(() => grantVerifies(denied, root)), isTrue);

    // And back.
    await tester.tap(toggle);
    await settle(tester);
    expect(shownBundle(tester).certificate.canInvite, isTrue);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a delegate who may invite but not grant sees no toggle', (
    tester,
  ) async {
    // creator → A (grant) → B (grant). B can invite, and cannot pass it on.
    late SavedRoom bRoom;
    await tester.runAsync(() async {
      final crypto = RoomMemberTransportIdentityCrypto();
      final root = await crypto.generateKeyPair();
      final a = await crypto.generateKeyPair();
      final b = await crypto.generateKeyPair();
      final roomId = RoomId('c' * 32);
      const aId = RoomMemberId('cccccccccccccccccccccc01');
      const bId = RoomMemberId('cccccccccccccccccccccc02');
      final aCert = await crypto.issueCertificate(
        roomId: roomId,
        memberId: aId,
        memberPublicKey: a.publicKey,
        issuer: root,
        grantInvite: true,
      );
      final bCert = await crypto.issueCertificate(
        roomId: roomId,
        memberId: bId,
        memberPublicKey: b.publicKey,
        issuer: a,
        issuerCertificate: aCert,
        grantInvite: true,
      );
      final now = DateTime.now().toUtc();
      bRoom = SavedRoom(
        room: Room(
          id: roomId,
          name: 'Deep ride',
          createdAt: now,
          updatedAt: now,
          members: [
            RoomMember(id: aId, displayName: 'A', joinedAt: now),
            RoomMember(id: bId, displayName: 'B', joinedAt: now),
          ],
        ),
        membership: const RoomMembership(
          localMemberId: bId,
          canManageInvites: true,
          ownsRoomKey: false,
        ),
      );
      await _seed(bRoom);
      await store.write(
        roomId: roomId,
        memberId: bId,
        material: RoomTransportIdentityMaterial(
          memberKeyPair: b,
          certificate: bCert,
        ),
      );
    });

    await tester.pumpWidget(
      app(
        OneScanRoomInviteSheet(
          repository: repository,
          identityLifecycle: identity,
        ),
      ),
    );
    await settle(tester);

    expect(find.byKey(const Key('one-scan-room-invite-qr')), findsOneWidget);
    expect(find.byKey(const Key('room-invite-grant-toggle')), findsNothing);
    final bundle = shownBundle(tester);
    expect(bundle.certificate.canInvite, isFalse);
    expect(bundle.certificate.issuerChain, hasLength(2));
  });

  testWidgets('a member without the right never reaches a sheet or a paywall', (
    tester,
  ) async {
    final now = DateTime.now().toUtc();
    const localId = RoomMemberId('dddddddddddddddddddddd01');
    final joined = SavedRoom(
      room: Room(
        id: RoomId('d' * 32),
        name: 'Closed ride',
        createdAt: now,
        updatedAt: now,
        members: [RoomMember(id: localId, displayName: 'Me', joinedAt: now)],
      ),
      membership: const RoomMembership(
        localMemberId: localId,
        canManageInvites: false,
      ),
    );
    await tester.runAsync(() => _seed(joined));
    late Future<bool> opened;
    await tester.pumpWidget(
      app(
        Builder(
          builder: (context) => TextButton(
            onPressed: () => opened = showOneScanRoomInviteSheet(
              context,
              repository: repository,
              identityLifecycle: identity,
            ),
            child: const Text('open'),
          ),
        ),
      ),
    );

    await tester.tap(find.text('open'));
    await settle(tester);

    expect(await opened, isFalse);
    expect(find.byType(OneScanRoomInviteSheet), findsNothing);
    expect(find.textContaining('You cannot invite people'), findsOneWidget);
  });
}

/// Writes [saved] the way storage does and selects it, so the sheet runs its
/// production path against a membership no UI could have created.
Future<void> _seed(SavedRoom saved) async {
  final id = saved.room.id.value;
  SharedPreferences.setMockInitialValues({
    'rooms.v1.index': [id],
    'rooms.v1.selected': id,
    'rooms.v1.room.$id': jsonEncode({
      'schemaVersion': 1,
      'id': id,
      'name': saved.room.name,
      'createdAt': saved.room.createdAt.toIso8601String(),
      'updatedAt': saved.room.updatedAt.toIso8601String(),
      'archived': false,
      'members': [
        for (final member in saved.room.members)
          {
            'id': member.id.value,
            'displayName': member.displayName,
            'joinedAt': member.joinedAt.toIso8601String(),
            'kind': member.kind.name,
          },
      ],
      'membership': {
        'localMemberId': saved.membership.localMemberId.value,
        'canManageInvites': saved.membership.canManageInvites,
        'active': true,
        'ownsRoomKey': saved.membership.ownsRoomKey,
      },
    }),
  });
}

final class _MemoryStore implements RoomTransportIdentitySecureStore {
  final Map<String, RoomTransportIdentityMaterial> _values = {};

  String _key(RoomId roomId, RoomMemberId memberId) =>
      '${roomId.value}:${memberId.value}';

  @override
  Future<void> delete({
    required RoomId roomId,
    required RoomMemberId memberId,
  }) async => _values.remove(_key(roomId, memberId));

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
  }) async => _values[_key(roomId, memberId)] = material;
}
