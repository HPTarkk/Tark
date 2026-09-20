import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:tark/core/l10n/app_localizations.dart';
import 'package:tark/feature/room/data/proximity/room_proximity_control_session_registry.dart';
import 'package:tark/feature/room/data/repository/shared_preferences_room_repository.dart';
import 'package:tark/feature/room/domain/entity/room.dart';
import 'package:tark/feature/room/domain/entity/room_invitation.dart';
import 'package:tark/feature/room/presentation/widget/one_scan_room_invite_sheet.dart';
import 'package:tark/feature/transfer/data/bluetooth/classic_bluetooth_engine.dart';
import 'package:tark/feature/transfer/data/service/room_proximity_control_channel.dart';
import 'package:tark/feature/transfer/domain/entity/bluetooth_peer.dart';

void main() {
  test(
    'modern Android Room invite requests every Bluetooth permission',
    () async {
      List<Permission>? requested;

      final granted = await ensureRoomInviteBluetoothPermissions(
        platform: TargetPlatform.android,
        sdkVersion: () async => 36,
        requestPermissions: (permissions) async {
          requested = List.of(permissions);
          return {
            for (final permission in permissions)
              permission: PermissionStatus.granted,
          };
        },
      );

      expect(granted, isTrue);
      expect(
        requested,
        containsAll(<Permission>[
          Permission.bluetoothScan,
          Permission.bluetoothConnect,
          Permission.bluetoothAdvertise,
        ]),
      );
      expect(requested, isNot(contains(Permission.locationWhenInUse)));
    },
  );

  test('pre-S Room invite also requests the legacy location gate', () async {
    List<Permission>? requested;

    await ensureRoomInviteBluetoothPermissions(
      platform: TargetPlatform.android,
      sdkVersion: () async => 30,
      requestPermissions: (permissions) async {
        requested = List.of(permissions);
        return {
          for (final permission in permissions)
            permission: PermissionStatus.granted,
        };
      },
    );

    expect(requested, contains(Permission.locationWhenInUse));
  });

  testWidgets(
    'creator permission grant issues invite, hosts proximity, and renders QR',
    (tester) async {
      SharedPreferences.setMockInitialValues({});
      final events = <String>[];
      final repository = _TracingRoomRepository(events);
      final room = await repository.create(
        name: 'Night ride',
        localDisplayName: 'Creator',
      );
      await repository.select(room.room.id);
      final engine = _FakeClassicBluetoothEngine(events);
      final control = RoomProximityControlChannel(engine: engine);

      await tester.pumpWidget(
        _host(
          repository: repository,
          control: control,
          permissionGate: () async {
            events.add('permissions');
            return true;
          },
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));

      expect(
        events,
        orderedEquals(<String>['permissions', 'issue_invitation', 'host']),
      );
      expect(find.byKey(const Key('one-scan-room-invite-qr')), findsOneWidget);
      expect(engine.hosted, isTrue);

      // The sheet has adopted this channel into the process-wide registry.
      // Do not synchronously dispose it from the widget tree: production owns
      // the session past sheet dismissal, and the test isolate owns final
      // cleanup. A different RoomId is used by every test invocation.
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets('native host readiness failure creates no usable QR', (
    tester,
  ) async {
    await tester.runAsync(RoomProximityControlSessionRegistry.instance.clear);
    SharedPreferences.setMockInitialValues({});
    final events = <String>[];
    final repository = _TracingRoomRepository(events);
    final room = await repository.create(
      name: 'Night ride',
      localDisplayName: 'Creator',
    );
    await repository.select(room.room.id);
    final control = RoomProximityControlChannel(
      engine: _FakeClassicBluetoothEngine(events, failHosting: true),
    );

    await tester.pumpWidget(
      _host(
        repository: repository,
        control: control,
        permissionGate: () async {
          events.add('permissions');
          return true;
        },
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));

    expect(
      events,
      orderedEquals(<String>['permissions', 'issue_invitation', 'host']),
    );
    expect(find.byKey(const Key('one-scan-room-invite-qr')), findsNothing);
    expect(find.byKey(const Key('one-scan-room-invite-retry')), findsOneWidget);
  });

  testWidgets('permission denial creates no invitation or fake QR', (
    tester,
  ) async {
    // An earlier test's invite is still adopted in the process-wide registry,
    // and adopting a new one releases it. Releasing awaits stream
    // cancellations, which fake async never completes — so release it for
    // real before this sheet gets that far.
    await tester.runAsync(RoomProximityControlSessionRegistry.instance.clear);
    SharedPreferences.setMockInitialValues({});
    final events = <String>[];
    final repository = _TracingRoomRepository(events);
    final room = await repository.create(
      name: 'Night ride',
      localDisplayName: 'Creator',
    );
    await repository.select(room.room.id);
    final control = RoomProximityControlChannel(
      engine: _FakeClassicBluetoothEngine(events),
    );
    var allow = false;

    await tester.pumpWidget(
      _host(
        repository: repository,
        control: control,
        permissionGate: () async {
          events.add('permissions');
          return allow;
        },
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    expect(events, orderedEquals(<String>['permissions']));
    expect(find.byKey(const Key('one-scan-room-invite-qr')), findsNothing);
    // Names what is missing and offers both ways past it, instead of a
    // generic "try again" with nothing to press.
    expect(
      find.text('Sharing an invite needs the Nearby devices permission.'),
      findsOneWidget,
    );
    expect(
      find.byKey(const Key('one-scan-room-invite-settings')),
      findsOneWidget,
    );

    allow = true;
    await tester.tap(find.byKey(const Key('one-scan-room-invite-retry')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));

    expect(
      events,
      orderedEquals(<String>[
        'permissions',
        'permissions',
        'issue_invitation',
        'host',
      ]),
    );
    expect(find.byKey(const Key('one-scan-room-invite-qr')), findsOneWidget);

    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('the sheet says who joined and gets out of the way', (
    tester,
  ) async {
    await tester.runAsync(RoomProximityControlSessionRegistry.instance.clear);
    SharedPreferences.setMockInitialValues({});
    final events = <String>[];
    final repository = _TracingRoomRepository(events);
    final room = await repository.create(
      name: 'Night ride',
      localDisplayName: 'Creator',
    );
    await repository.select(room.room.id);
    final control = RoomProximityControlChannel(
      engine: _FakeClassicBluetoothEngine(events),
    );

    await tester.pumpWidget(
      _host(
        repository: repository,
        control: control,
        permissionGate: () async => true,
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.byKey(const Key('one-scan-room-invite-qr')), findsOneWidget);
    expect(find.byKey(const Key('one-scan-room-invite-copy')), findsNothing);

    final now = DateTime.now().toUtc();
    final verified = await repository.verifyAndRedeemInvite(
      repository.lastInvite!,
      now: now,
    );
    await repository.acceptVerifiedInvite(
      verified!,
      displayName: 'Rider two',
      acceptedAt: now,
      pending: false,
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));

    expect(find.text('Rider two joined'), findsOneWidget);
    expect(find.byKey(const Key('one-scan-room-invite-qr')), findsNothing);

    await tester.pump(const Duration(seconds: 2));
    await tester.pumpWidget(const SizedBox.shrink());
  });
}

Widget _host({
  required SharedPreferencesRoomRepository repository,
  required RoomProximityControlChannel control,
  required Future<bool> Function() permissionGate,
}) => MaterialApp(
  locale: const Locale('en'),
  supportedLocales: AppLocalizations.supportedLocales,
  localizationsDelegates: AppLocalizations.localizationsDelegates,
  home: Scaffold(
    body: OneScanRoomInviteSheet(
      repository: repository,
      controlChannel: control,
      permissionGate: permissionGate,
    ),
  ),
);

final class _TracingRoomRepository extends SharedPreferencesRoomRepository {
  _TracingRoomRepository(this.events);

  final List<String> events;
  RoomInvitation? lastInvite;

  @override
  Future<RoomInvitation> issueInvite(
    RoomId id, {
    required RoomInvitationKind kind,
    required DateTime now,
    required Duration ttl,
    RoomTransportBootstrap? transportBootstrap,
  }) async {
    events.add('issue_invitation');
    return lastInvite = await super.issueInvite(
      id,
      kind: kind,
      now: now,
      ttl: ttl,
      transportBootstrap: transportBootstrap,
    );
  }
}

final class _FakeClassicBluetoothEngine extends ClassicBluetoothEngine {
  _FakeClassicBluetoothEngine(this.events, {this.failHosting = false});

  final List<String> events;
  final bool failHosting;
  final StreamController<Uint8List> _input = StreamController.broadcast();
  final StreamController<String> _connected = StreamController.broadcast();
  final StreamController<String> _errors = StreamController.broadcast();
  final StreamController<void> _closed = StreamController.broadcast();
  bool hosted = false;

  @override
  Stream<Uint8List> get input => _input.stream;

  @override
  Stream<String> get onPeerConnected => _connected.stream;

  @override
  Stream<String> get onError => _errors.stream;

  @override
  Stream<void> get onClosed => _closed.stream;

  @override
  Future<bool> requestDiscoverable({int durationSeconds = 300}) async => true;

  @override
  Future<void> startHosting({String name = 'tark'}) async {
    events.add('host');
    hosted = true;
    if (failHosting) throw StateError('native host readiness failed');
  }

  @override
  Future<void> stopHosting() async {}

  @override
  Stream<BluetoothPeer> scanForHosts() => const Stream.empty();

  @override
  void cancelDiscovery() {}

  @override
  Future<void> write(Uint8List bytes) async {}

  @override
  Future<void> dispose() async {}
}
