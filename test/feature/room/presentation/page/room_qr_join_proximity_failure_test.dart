import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:tark/core/l10n/app_localizations.dart';
import 'package:tark/core/router/routes.dart';
import 'package:tark/core/widget/qr_scanner_surface.dart';
import 'package:tark/feature/room/domain/entity/room.dart';
import 'package:tark/feature/room/domain/entity/room_invitation.dart';
import 'package:tark/feature/room/presentation/manager/room_list_cubit.dart';
import 'package:tark/feature/room/presentation/page/room_qr_join_page.dart';
import 'package:tark/feature/transfer/data/bluetooth/classic_bluetooth_engine.dart';
import 'package:tark/feature/transfer/data/service/room_proximity_control_channel.dart';
import 'package:tark/feature/transfer/domain/entity/bluetooth_peer.dart';

/// What the joining phone says when the Bluetooth half of a one-scan join
/// cannot happen.
///
/// Each of these used to end the same way: the scanner stuck on "joining the
/// room" with no timeout, and every further scan ignored because a join was
/// still in flight.
///
/// A failed attempt releases its control channel, and releasing one awaits
/// stream cancellations — which fake async never completes. So the scans that
/// get as far as Bluetooth run under [WidgetTester.runAsync].
void main() {
  const roomId = RoomId('aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa');
  const invitationId = '0123456789abcdef0123456789abcdef';
  final invite = RoomInvitation(
    version: RoomInvitation.currentVersion,
    roomId: roomId,
    invitationId: invitationId,
    secret: 'b' * 64,
    kind: RoomInvitationKind.trustedMembership,
    issuedAt: DateTime.utc(2026, 9, 1),
    expiresAt: DateTime.utc(2099),
    singleUse: false,
    displayCode: roomInviteDisplayCode(roomId, invitationId),
  ).encode();

  late _Engine engine;

  Future<QrScannerSurface> pumpScanner(
    WidgetTester tester, {
    required bool permitted,
    bool bluetoothOn = true,
    Duration findTimeout = const Duration(seconds: 30),
  }) async {
    engine = _Engine(bluetoothOn: bluetoothOn);
    final router = GoRouter(
      initialLocation: AppRoutes.roomQrJoinPath,
      routes: [
        GoRoute(
          path: AppRoutes.roomQrJoinPath,
          builder: (_, _) => RoomQrJoinPage(
            cubit: _FakeRoomList(),
            permissionGate: () async => permitted,
            controlChannelFactory: () => RoomProximityControlChannel(
              engine: engine,
              findTimeout: findTimeout,
            ),
          ),
        ),
      ],
    );
    addTearDown(router.dispose);
    await tester.pumpWidget(
      MaterialApp.router(
        locale: const Locale('en'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        routerConfig: router,
      ),
    );
    await tester.pump(const Duration(milliseconds: 100));
    return tester.widget<QrScannerSurface>(find.byType(QrScannerSurface));
  }

  String? errorOn(WidgetTester tester) =>
      tester.widget<QrScannerSurface>(find.byType(QrScannerSurface)).errorText;

  testWidgets('without the Bluetooth permission it says so and never scans', (
    tester,
  ) async {
    final surface = await pumpScanner(tester, permitted: false);

    expect(await surface.onCode(invite), isFalse);
    await tester.pump();

    expect(
      errorOn(tester),
      'Joining needs the Nearby devices permission. Allow it, then scan again.',
    );
    expect(engine.scanned, isFalse);
  });

  testWidgets('with Bluetooth off it says so instead of scanning in silence', (
    tester,
  ) async {
    final surface = await pumpScanner(
      tester,
      permitted: true,
      bluetoothOn: false,
    );

    expect(await tester.runAsync(() => surface.onCode(invite)), isFalse);
    await tester.pump();

    expect(errorOn(tester), 'Turn on Bluetooth, then scan again.');
    expect(engine.scanned, isFalse);
  });

  testWidgets('a host that never turns up times out and re-arms the scanner', (
    tester,
  ) async {
    final surface = await pumpScanner(
      tester,
      permitted: true,
      findTimeout: const Duration(milliseconds: 50),
    );

    expect(await tester.runAsync(() => surface.onCode(invite)), isFalse);
    await tester.pump();

    expect(
      errorOn(tester),
      "Couldn't find their phone. Keep the invite open on it, stay close, and "
      'scan again.',
    );
    expect(engine.scanned, isTrue);
    expect(engine.dialed, isFalse);
  });
}

class _FakeRoomList implements RoomListCubit {
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError(invocation.memberName.toString());
}

class _Engine extends ClassicBluetoothEngine {
  _Engine({required this.bluetoothOn});

  final bool bluetoothOn;
  final _results = StreamController<BluetoothPeer>.broadcast();
  final _input = StreamController<Uint8List>.broadcast();
  final _connected = StreamController<String>.broadcast();
  final _errors = StreamController<String>.broadcast();
  final _closed = StreamController<void>.broadcast();
  bool scanned = false;
  bool dialed = false;

  @override
  Future<bool> get isEnabled async => bluetoothOn;

  @override
  Future<bool> requestEnable() async => false;

  @override
  Stream<Uint8List> get input => _input.stream;

  @override
  Stream<String> get onPeerConnected => _connected.stream;

  @override
  Stream<String> get onError => _errors.stream;

  @override
  Stream<void> get onClosed => _closed.stream;

  @override
  Stream<BluetoothPeer> scanForHosts() {
    scanned = true;
    return _results.stream;
  }

  @override
  void cancelDiscovery() {}

  @override
  Future<void> connectToHost(String address) async {
    dialed = true;
  }

  @override
  Future<void> write(Uint8List bytes) async {}

  @override
  Future<void> dispose() async {}
}
