import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:tark/core/l10n/app_localizations.dart';
import 'package:tark/feature/room/data/repository/shared_preferences_room_repository.dart';
import 'package:tark/feature/room/data/security/room_transport_identity_lifecycle.dart';
import 'package:tark/feature/room/data/security/room_transport_identity_secure_store.dart';
import 'package:tark/feature/room/domain/entity/room.dart';
import 'package:tark/feature/room/presentation/widget/one_scan_room_invite_sheet.dart';
import 'package:tark/feature/transfer/api/hotspot_invite_api.dart';
import 'package:tark/feature/transfer/api/transfer_api.dart';

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });

  Future<SharedPreferencesRoomRepository> repositoryWithSelectedRoom() async {
    final repository = SharedPreferencesRoomRepository();
    final saved = await repository.create(
      name: 'Night ride',
      localDisplayName: 'Host',
    );
    await repository.select(saved.room.id);
    return repository;
  }

  Widget inviteApp({
    required SharedPreferencesRoomRepository repository,
    required PreLiveHotspotBootstrap bootstrap,
  }) => MaterialApp(
    locale: const Locale('en'),
    supportedLocales: AppLocalizations.supportedLocales,
    localizationsDelegates: AppLocalizations.localizationsDelegates,
    home: Scaffold(
      body: OneScanRoomInviteSheet(
        repository: repository,
        identityLifecycle: RoomTransportIdentityLifecycle(
          store: _MemoryIdentityStore(),
        ),
        bootstrapHost: true,
        preLiveBootstrap: bootstrap,
      ),
    ),
  );

  Future<void> beat(WidgetTester tester) async {
    for (var i = 0; i < 20; i++) {
      await tester.pump(const Duration(milliseconds: 60));
    }
  }

  testWidgets(
    'cold first invite renders while hotspot bootstrap is still pending',
    (tester) async {
      final repository = await repositoryWithSelectedRoom();
      final hotspotReady = Completer<HotspotCredentials?>();

      await tester.pumpWidget(
        inviteApp(
          repository: repository,
          bootstrap: PreLiveHotspotBootstrap(
            starter: () => hotspotReady.future,
          ),
        ),
      );
      await beat(tester);

      expect(hotspotReady.isCompleted, isFalse);
      expect(find.byKey(const Key('one-scan-room-invite-qr')), findsOneWidget);
      expect(find.byType(CircularProgressIndicator), findsNothing);
      expect((await repository.list()).single.room.pendingMembers, hasLength(1));
      expect(tester.takeException(), isNull);
    },
  );

  test('startup composition bypasses ConsentGate but keeps legal code', () async {
    final app = await File('lib/app/my_app.dart').readAsString();
    final gate = File(
      'lib/feature/legal/presentation/widget/consent_gate.dart',
    );

    expect(
      app,
      isNot(contains("feature/legal/presentation/widget/consent_gate.dart")),
    );
    expect(app, isNot(contains('ConsentGate(child: child!)')));
    expect(app, contains('child: child!'));
    expect(await gate.exists(), isTrue);
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
