import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:tark/feature/transfer/data/android_network_binding.dart';
import 'package:tark/feature/transfer/data/android_network_rebind_coordinator.dart';
import 'package:tark/feature/transfer/data/service/session_role_store_impl.dart';
import 'package:tark/feature/transfer/domain/entity/session_role.dart';
import 'package:tark/feature/transfer/domain/entity/transfer_mode.dart';
import 'package:tark/feature/transfer/domain/service/transfer_mode_store.dart';

void main() {
  const wifi = AndroidNetworkSelection(
    generation: 33,
    available: true,
    networkHandle: 7331,
    interfaceName: 'wlan0',
    isWifi: true,
  );

  test(
    'late joiner role reconciles an already-selected Wi-Fi network',
    () async {
      final modes = _ModeStore(TransferMode.hotspot);
      final roles = SessionRoleStoreImpl()..setRole(SessionRole.host);
      final port = _BindingPort(currentSelection: wifi);
      var socketRebinds = 0;
      final coordinator = AndroidNetworkRebindCoordinator(
        () => socketRebinds++,
        modes,
        roles,
        port: port,
      );

      await coordinator.start();
      port.emit(wifi);
      await _settle();

      expect(port.bindGenerations, isEmpty);
      expect(socketRebinds, 0);

      roles.setRole(SessionRole.joiner);
      await _settle();

      expect(port.bindGenerations, [33]);
      expect(socketRebinds, 1);

      // Repeating the same role is not a new epoch and must not duplicate work.
      roles.setRole(SessionRole.joiner);
      await _settle();
      expect(port.bindGenerations, [33]);
      expect(socketRebinds, 1);

      await coordinator.dispose();
      await modes.dispose();
      await port.dispose();
    },
  );

  group('a host whose peer is on the router', () {
    final now = DateTime.utc(2026, 10, 16, 18, 23);

    test('decides from where the peer was last heard', () {
      bool needs(
        Map<String, DateTime> heard, {
        String? station = '192.168.8.107',
      }) => AndroidNetworkRebindCoordinator.hostNeedsRouter(
        heard: heard,
        station: station,
        now: now,
      );
      expect(needs({'192.168.8.155': now}), isTrue);
      // On the access point: the router is no use to it.
      expect(needs({'10.14.189.134': now}), isFalse);
      expect(needs({'192.168.8.155': now, '10.14.189.134': now}), isFalse);
      // Gone quiet on the router: it is on its way to the access point.
      expect(
        needs({'192.168.8.155': now.subtract(const Duration(seconds: 4))}),
        isFalse,
      );
      // Not a client of any router: nothing to pin to.
      expect(needs({'192.168.8.155': now}, station: null), isFalse);
      expect(needs(const {}), isFalse);
    });

    test('pins while the peer is on the router, lets go once it leaves, and '
        'pins again when it comes back', () async {
      final modes = _ModeStore(TransferMode.wifi);
      final roles = SessionRoleStoreImpl()..setRole(SessionRole.joiner);
      final port = _BindingPort(currentSelection: wifi);
      var socketRebinds = 0;
      var heard = <String, DateTime>{'192.168.8.155': DateTime.now()};
      final coordinator = AndroidNetworkRebindCoordinator(
        () => socketRebinds++,
        modes,
        roles,
        port: port,
        peersHeardAt: () => heard,
        stationAddress: () async => '192.168.8.107',
        bridgeTick: const Duration(milliseconds: 20),
      );
      await coordinator.start();
      expect(port.bindGenerations, [33]);

      // Elected host for the move, the other phone still on the router.
      roles.setRole(SessionRole.host);
      await Future<void>.delayed(const Duration(milliseconds: 80));
      expect(port.clearCount, 1);
      expect(port.bindGenerations, [33, 33]);

      // It joins the access point: silent on the router, heard on the AP.
      heard = {'10.14.189.134': DateTime.now()};
      await Future<void>.delayed(const Duration(milliseconds: 80));
      expect(port.clearCount, 2);

      // Android 9 drops it back onto the router.
      heard = {'192.168.8.155': DateTime.now()};
      await Future<void>.delayed(const Duration(milliseconds: 80));
      expect(port.bindGenerations, [33, 33, 33]);

      // Stops hosting: the bridge stands down with it.
      roles.setRole(SessionRole.joiner);
      await _settle();
      final rebindsBefore = socketRebinds;
      heard = {'10.14.189.134': DateTime.now()};
      await Future<void>.delayed(const Duration(milliseconds: 80));
      expect(port.clearCount, 2);
      expect(socketRebinds, rebindsBefore);

      await coordinator.dispose();
      await modes.dispose();
      await port.dispose();
    });
  });

  test('role change back to host clears a client process binding', () async {
    final modes = _ModeStore(TransferMode.hotspot);
    final roles = SessionRoleStoreImpl()..setRole(SessionRole.joiner);
    final port = _BindingPort(currentSelection: wifi);
    var socketRebinds = 0;
    final coordinator = AndroidNetworkRebindCoordinator(
      () => socketRebinds++,
      modes,
      roles,
      port: port,
    );

    await coordinator.start();
    expect(port.bindGenerations, [33]);

    roles.setRole(SessionRole.host);
    await _settle();
    expect(port.clearCount, 1);
    // Sockets made under the client pin would stay on the router.
    expect(socketRebinds, 1);

    await coordinator.dispose();
    final clearsAtDispose = port.clearCount;

    roles.setRole(SessionRole.joiner);
    await _settle();
    expect(port.clearCount, clearsAtDispose);
    expect(port.bindGenerations, [33]);
    // Once, when the host side unpinned the process; none after dispose.
    expect(socketRebinds, 1);

    await modes.dispose();
    await port.dispose();
  });

  test('stale host clear cannot win over a newer joiner bind', () async {
    final modes = _ModeStore(TransferMode.hotspot);
    final roles = SessionRoleStoreImpl()..setRole(SessionRole.joiner);
    final clearGate = Completer<void>();
    final port = _BindingPort(currentSelection: wifi, clearGate: clearGate);
    var socketRebinds = 0;
    final coordinator = AndroidNetworkRebindCoordinator(
      () => socketRebinds++,
      modes,
      roles,
      port: port,
    );

    await coordinator.start();
    expect(port.bindGenerations, [33]);

    // Begin the host-side clear but hold it inside the platform boundary.
    roles.setRole(SessionRole.host);
    await _settle();
    expect(port.clearCount, 1);

    // One-scan bootstrap settles back to joiner before the old clear returns.
    roles.setRole(SessionRole.joiner);
    await _settle();
    expect(port.bindGenerations, [33, 33]);

    // The stale clear lands last. The coordinator must notice its role epoch is
    // obsolete, forget the optimistic binding, and re-pin the current Wi-Fi.
    clearGate.complete();
    await _settle();
    await _settle();
    expect(port.bindGenerations, [33, 33, 33]);
    expect(socketRebinds, 2);

    await coordinator.dispose();
    await modes.dispose();
    await port.dispose();
  });

  test('in-flight initial joiner bind cannot pin a newly-hosting device', () async {
    final modes = _ModeStore(TransferMode.hotspot);
    final roles = SessionRoleStoreImpl()..setRole(SessionRole.joiner);
    final bindGate = Completer<void>();
    final port = _BindingPort(currentSelection: wifi, bindGate: bindGate);
    final coordinator = AndroidNetworkRebindCoordinator(
      () {},
      modes,
      roles,
      port: port,
    );

    final starting = coordinator.start();
    await _settle();
    expect(port.bindGenerations, [33]);

    // Role election finishes while Android is still processing the joiner bind.
    roles.setRole(SessionRole.host);
    await _settle();
    expect(port.clearCount, 1);

    bindGate.complete();
    await starting;
    await _settle();

    // The late bind cannot be allowed to become the host's final process route.
    expect(port.clearCount, 2);

    await coordinator.dispose();
    await modes.dispose();
    await port.dispose();
  });
}

Future<void> _settle() async {
  await Future<void>.delayed(Duration.zero);
  await Future<void>.delayed(Duration.zero);
}

final class _ModeStore implements TransferModeStore {
  _ModeStore(this._mode);

  TransferMode _mode;
  TransferMode? _pinned;
  final _modes = StreamController<TransferMode>.broadcast(sync: true);
  final _pins = StreamController<TransferMode?>.broadcast(sync: true);

  @override
  TransferMode get mode => _mode;

  @override
  Stream<TransferMode> get modeChanges => _modes.stream;

  @override
  TransferMode? get pinnedMode => _pinned;

  @override
  Stream<TransferMode?> get pinChanges => _pins.stream;

  @override
  Future<void> initialize() async {}

  @override
  Future<void> setMode(TransferMode mode) async {
    if (_mode == mode) return;
    _mode = mode;
    _modes.add(mode);
  }

  @override
  Future<void> setPinnedMode(TransferMode? mode) async {
    _pinned = mode;
    _pins.add(mode);
    if (mode != null) await setMode(mode);
  }

  Future<void> dispose() async {
    await _modes.close();
    await _pins.close();
  }
}

final class _BindingPort implements AndroidNetworkBindingPort {
  _BindingPort({this.currentSelection, this.clearGate, this.bindGate});

  AndroidNetworkSelection? currentSelection;
  final Completer<void>? clearGate;
  final Completer<void>? bindGate;
  final _changes = StreamController<AndroidNetworkSelection>.broadcast(
    sync: true,
  );
  final List<int> bindGenerations = [];
  int clearCount = 0;

  @override
  Future<AndroidNetworkSelection?> current() async => currentSelection;

  @override
  Stream<AndroidNetworkSelection> get changes => _changes.stream;

  @override
  Future<bool> bind(AndroidNetworkSelection selection) async {
    bindGenerations.add(selection.generation);
    await bindGate?.future;
    return true;
  }

  @override
  Future<void> clear() async {
    clearCount++;
    await clearGate?.future;
  }

  void emit(AndroidNetworkSelection selection) {
    currentSelection = selection;
    _changes.add(selection);
  }

  Future<void> dispose() => _changes.close();
}
