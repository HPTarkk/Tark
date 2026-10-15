import 'package:flutter_test/flutter_test.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:tark/core/permission/permission_flow.dart';
import 'package:tark/core/permission/permission_kind.dart';

import 'fake_permission_backend.dart';

void main() {
  PermissionFlowController flow(
    FakePermissionBackend backend, {
    List<Permission> permissions = const [Permission.microphone],
    PermissionKind kind = PermissionKind.microphone,
  }) => PermissionFlowController(
    permissions: permissions,
    kind: kind,
    backend: backend,
  );

  group('PermissionFlowController', () {
    test('already granted: no primer, no request', () async {
      final backend = FakePermissionBackend(
        current: {Permission.microphone: PermissionStatus.granted},
      );
      final f = flow(backend);
      await f.start();
      expect(f.phase, PermissionFlowPhase.granted);
      expect(f.needed, isFalse);
      expect(backend.requests, 0);
    });

    test('not granted -> primer -> allow -> granted', () async {
      final backend = FakePermissionBackend();
      final f = flow(backend);
      final phases = <PermissionFlowPhase>[];
      f.addListener(() => phases.add(f.phase));
      await f.start();
      expect(f.phase, PermissionFlowPhase.primer);
      expect(backend.requests, 0, reason: 'the OS is never asked first');
      await f.allow();
      expect(phases, [
        PermissionFlowPhase.primer,
        PermissionFlowPhase.requesting,
        PermissionFlowPhase.granted,
      ]);
      expect(backend.requests, 1);
      expect(f.allGranted, isTrue);
    });

    test('primer -> allow -> denied -> try again -> granted', () async {
      final backend = FakePermissionBackend(
        answers: [PermissionStatus.denied, PermissionStatus.granted],
      );
      final f = flow(backend);
      await f.start();
      await f.allow();
      expect(f.phase, PermissionFlowPhase.denied);
      await f.retry();
      expect(f.phase, PermissionFlowPhase.granted);
      expect(backend.requests, 2);
    });

    test('a second refusal Android turns permanent lands on blocked, and '
        'Settings is the way on', () async {
      final backend = FakePermissionBackend(
        answers: [PermissionStatus.denied, PermissionStatus.permanentlyDenied],
      );
      final f = flow(backend);
      await f.start();
      await f.allow();
      await f.retry();
      expect(f.phase, PermissionFlowPhase.blocked);

      await f.openSettings();
      expect(f.phase, PermissionFlowPhase.settings);
      expect(backend.settingsOpened, 1);

      // Back from Settings, still off: blocked again, nothing re-asked.
      await f.recheck();
      expect(f.phase, PermissionFlowPhase.blocked);
      expect(backend.requests, 2);

      // Switched on in Settings: picked up on return.
      await f.openSettings();
      backend.current[Permission.microphone] = PermissionStatus.granted;
      await f.recheck();
      expect(f.phase, PermissionFlowPhase.granted);
    });

    test('blocked before anything was asked: the primer leads to Settings, '
        'never to a dialog Android would not show', () async {
      final backend = FakePermissionBackend(
        current: {Permission.microphone: PermissionStatus.permanentlyDenied},
      );
      final f = flow(backend);
      await f.start();
      expect(f.phase, PermissionFlowPhase.primer);
      expect(f.blockedAtStart, isTrue);
      await f.allow();
      expect(f.phase, PermissionFlowPhase.settings);
      expect(backend.requests, 0);
      expect(backend.settingsOpened, 1);
    });

    test('restricted counts as blocked', () async {
      final backend = FakePermissionBackend(
        answers: [PermissionStatus.restricted],
      );
      final f = flow(backend);
      await f.start();
      await f.allow();
      expect(f.phase, PermissionFlowPhase.blocked);
    });

    test('not now is terminal and asks nothing', () async {
      final backend = FakePermissionBackend();
      final f = flow(backend);
      await f.start();
      f.notNow();
      expect(f.phase, PermissionFlowPhase.dismissed);
      await f.allow();
      expect(backend.requests, 0);
      expect(f.allGranted, isFalse);
    });

    test('only the missing permissions are asked for', () async {
      final backend = FakePermissionBackend(
        current: {
          Permission.bluetoothScan: PermissionStatus.granted,
          Permission.bluetoothConnect: PermissionStatus.granted,
          Permission.bluetoothAdvertise: PermissionStatus.granted,
        },
      );
      final f = flow(
        backend,
        permissions: const [
          Permission.bluetoothScan,
          Permission.bluetoothConnect,
          Permission.bluetoothAdvertise,
          Permission.locationWhenInUse,
        ],
        kind: PermissionKind.nearbyDevices,
      );
      await f.start();
      // Pre-S: the trio reads granted and only location is really asked, so
      // the primer talks about location, not "nearby devices".
      expect(f.visualKind, PermissionKind.location);
      await f.allow();
      expect(backend.asked.single, [Permission.locationWhenInUse]);
      expect(f.phase, PermissionFlowPhase.granted);
    });

    test('a request that throws falls back to reading the status', () async {
      final backend = _ThrowingRequestBackend();
      final f = flow(backend);
      await f.start();
      await f.allow();
      expect(f.phase, PermissionFlowPhase.denied);
    });
  });

  group('PermissionKind', () {
    test('infers the kind from the permissions', () {
      expect(
        PermissionKind.of(const [Permission.microphone]),
        PermissionKind.microphone,
      );
      expect(
        PermissionKind.of(const [Permission.camera]),
        PermissionKind.camera,
      );
      expect(
        PermissionKind.of(const [
          Permission.bluetoothScan,
          Permission.locationWhenInUse,
        ]),
        PermissionKind.nearbyDevices,
      );
      expect(
        PermissionKind.of(const [Permission.nearbyWifiDevices]),
        PermissionKind.nearbyWifi,
      );
      expect(
        PermissionKind.of(const [Permission.locationWhenInUse]),
        PermissionKind.location,
      );
      expect(
        PermissionKind.of(const [Permission.notification]),
        PermissionKind.notifications,
      );
    });

    test('the hotspot on pre-T Android is shown as location', () {
      expect(
        PermissionKind.visualFor(PermissionKind.nearbyWifi, const [
          Permission.locationWhenInUse,
        ]),
        PermissionKind.location,
      );
      expect(
        PermissionKind.visualFor(PermissionKind.nearbyWifi, const [
          Permission.nearbyWifiDevices,
        ]),
        PermissionKind.nearbyWifi,
      );
    });
  });
}

class _ThrowingRequestBackend extends FakePermissionBackend {
  @override
  Future<Map<Permission, PermissionStatus>> request(
    List<Permission> permissions,
  ) => Future.error(StateError('dialog dropped'));
}
