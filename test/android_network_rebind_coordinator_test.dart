import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:tark/feature/transfer/data/android_network_binding.dart';
import 'package:tark/feature/transfer/data/android_network_rebind_coordinator.dart';
import 'package:tark/feature/transfer/domain/entity/transfer_mode.dart';
import 'package:tark/feature/transfer/domain/service/transfer_mode_store.dart';

void main() {
  AndroidNetworkSelection wifi(int generation, {bool vpn = false}) =>
      AndroidNetworkSelection(
        generation: generation,
        available: true,
        networkHandle: 100 + generation,
        interfaceName: 'wlan0',
        isWifi: true,
        isVpn: vpn,
      );

  test('new selected Wi-Fi generation rebinds sockets exactly once', () async {
    final modes = _FakeModeStore(TransferMode.wifi);
    final port = _FakeBindingPort(wifi(1));
    var rebinds = 0;
    final coordinator = AndroidNetworkRebindCoordinator(
      () => rebinds++,
      modes,
      port: port,
    );

    await coordinator.start();
    expect(port.boundGenerations, [1]);
    expect(rebinds, 0);

    port.emit(wifi(2));
    await pumpEventQueue();
    expect(port.boundGenerations, [1, 2]);
    expect(rebinds, 1);

    port.emit(wifi(2));
    await pumpEventQueue();
    expect(rebinds, 1);

    await coordinator.dispose();
    await modes.dispose();
    await port.dispose();
  });

  test(
    'VPN selection is ignored and cannot rebuild local UDP sockets',
    () async {
      final modes = _FakeModeStore(TransferMode.wifi);
      final port = _FakeBindingPort(wifi(1));
      var rebinds = 0;
      final coordinator = AndroidNetworkRebindCoordinator(
        () => rebinds++,
        modes,
        port: port,
      );

      await coordinator.start();
      port.emit(wifi(2, vpn: true));
      await pumpEventQueue();

      expect(port.boundGenerations, [1]);
      expect(rebinds, 0);

      await coordinator.dispose();
      await modes.dispose();
      await port.dispose();
    },
  );

  test(
    'leaving local Wi-Fi mode clears binding and ignores later callbacks',
    () async {
      final modes = _FakeModeStore(TransferMode.hotspot);
      final port = _FakeBindingPort(wifi(4));
      var rebinds = 0;
      final coordinator = AndroidNetworkRebindCoordinator(
        () => rebinds++,
        modes,
        port: port,
      );

      await coordinator.start();
      await modes.setMode(TransferMode.bluetooth);
      await pumpEventQueue();
      final clearsAfterModeChange = port.clearCount;

      port.emit(wifi(5));
      await pumpEventQueue();

      expect(clearsAfterModeChange, 1);
      expect(rebinds, 0);

      await coordinator.dispose();
      expect(port.clearCount, 2);
      await modes.dispose();
      await port.dispose();
    },
  );

  test(
    'stale asynchronous bind cannot overwrite a newer transport mode',
    () async {
      final modes = _FakeModeStore(TransferMode.wifi);
      final port = _FakeBindingPort(wifi(1));
      var rebinds = 0;
      final coordinator = AndroidNetworkRebindCoordinator(
        () => rebinds++,
        modes,
        port: port,
      );

      await coordinator.start();
      port.holdBinds = true;
      port.emit(wifi(2));
      await pumpEventQueue();
      await modes.setMode(TransferMode.guest);
      await pumpEventQueue();

      port.releaseHeldBind(true);
      await pumpEventQueue();

      expect(rebinds, 0);
      expect(port.clearCount, 1);

      await coordinator.dispose();
      await modes.dispose();
      await port.dispose();
    },
  );
}

final class _FakeBindingPort implements AndroidNetworkBindingPort {
  _FakeBindingPort(this.selection);

  AndroidNetworkSelection selection;
  final _changes = StreamController<AndroidNetworkSelection>.broadcast();
  final List<int> boundGenerations = [];
  int clearCount = 0;
  bool holdBinds = false;
  Completer<bool>? _heldBind;

  @override
  Stream<AndroidNetworkSelection> get changes => _changes.stream;

  @override
  Future<AndroidNetworkSelection?> current() async => selection;

  @override
  Future<bool> bind(AndroidNetworkSelection value) async {
    if (holdBinds) {
      _heldBind = Completer<bool>();
      final result = await _heldBind!.future;
      if (result) boundGenerations.add(value.generation);
      return result;
    }
    boundGenerations.add(value.generation);
    return true;
  }

  @override
  Future<void> clear() async {
    clearCount++;
  }

  void emit(AndroidNetworkSelection value) {
    selection = value;
    _changes.add(value);
  }

  void releaseHeldBind(bool value) {
    final held = _heldBind;
    if (held != null && !held.isCompleted) held.complete(value);
    holdBinds = false;
  }

  Future<void> dispose() => _changes.close();
}

final class _FakeModeStore implements TransferModeStore {
  _FakeModeStore(this._mode);

  TransferMode _mode;
  final _modeChanges = StreamController<TransferMode>.broadcast();
  final _pinChanges = StreamController<TransferMode?>.broadcast();
  TransferMode? _pinned;

  @override
  TransferMode get mode => _mode;

  @override
  Stream<TransferMode> get modeChanges => _modeChanges.stream;

  @override
  TransferMode? get pinnedMode => _pinned;

  @override
  Stream<TransferMode?> get pinChanges => _pinChanges.stream;

  @override
  Future<void> initialize() async {}

  @override
  Future<void> setMode(TransferMode mode) async {
    _mode = mode;
    _modeChanges.add(mode);
  }

  @override
  Future<void> setPinnedMode(TransferMode? mode) async {
    _pinned = mode;
    _pinChanges.add(mode);
    if (mode != null) await setMode(mode);
  }

  Future<void> dispose() async {
    await _modeChanges.close();
    await _pinChanges.close();
  }
}
