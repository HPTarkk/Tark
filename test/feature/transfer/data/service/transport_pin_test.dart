import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:tark/core/entitlement/entitlement.dart';
import 'package:tark/core/entitlement/license_gate.dart';
import 'package:tark/core/entitlement/premium_feature.dart';
import 'package:tark/core/settings/settings_keys.dart';
import 'package:tark/feature/transfer/data/service/transfer_mode_store_impl.dart';
import 'package:tark/feature/transfer/domain/entity/session_role.dart';
import 'package:tark/feature/transfer/domain/entity/transfer_mode.dart';
import 'package:tark/feature/transfer/domain/service/session_role_store.dart';

class _FakeRoleStore implements SessionRoleStore {
  SessionRole? _role;
  var clears = 0;

  @override
  SessionRole? get role => _role;

  @override
  void setRole(SessionRole role) => _role = role;

  @override
  void clear() {
    clears++;
    _role = null;
  }
}

class _FakeGate implements LicenseGate {
  _FakeGate({this.unlocked = true});

  final bool unlocked;

  @override
  bool allows(PremiumFeature feature) => unlocked;

  @override
  bool get canPurchase => !unlocked;

  @override
  Stream<Entitlement> get changes => const Stream<Entitlement>.empty();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Future<TransferModeStoreImpl> store(
    Map<String, Object> initial, {
    bool unlocked = true,
    _FakeRoleStore? roles,
  }) async {
    SharedPreferences.setMockInitialValues(initial);
    final impl = TransferModeStoreImpl(
      await SharedPreferences.getInstance(),
      roles ?? _FakeRoleStore(),
      _FakeGate(unlocked: unlocked),
    );
    await impl.initialize();
    return impl;
  }

  Future<Object?> readKey(String key) async =>
      (await SharedPreferences.getInstance()).getString(key);

  group('automatic is the default, and stays the default', () {
    // The single most important case: everything that shipped before the pin
    // existed has a `transport_mode` and no `transport_pin`, and every one of
    // those installs must come back automatic. Reading the pin with
    // `TransferMode.fromKey` — which answers Wi-Fi for an absent value — would
    // silently pin the entire existing user base and make the advisor dead
    // code on upgrade.
    test('an install predating the pin reads as automatic', () async {
      final s = await store({SettingsKeys.transportMode: 'bluetooth'});
      expect(s.pinnedMode, isNull);
      // …while still remembering what it was actually using, which is what
      // the DI factory and quick access read at cold start.
      expect(s.mode, TransferMode.bluetooth);
    });

    test('a fresh install is automatic', () async {
      expect((await store({})).pinnedMode, isNull);
    });

    test('a stored "auto" is automatic', () async {
      final s = await store({SettingsKeys.transportPin: 'auto'});
      expect(s.pinnedMode, isNull);
    });

    test('an unrecognised stored pin is automatic, not a guess', () async {
      final s = await store({SettingsKeys.transportPin: 'carrier-pigeon'});
      expect(s.pinnedMode, isNull);
    });
  });

  group('pinning', () {
    test('survives a restart', () async {
      final s = await store({});
      await s.setPinnedMode(TransferMode.bluetooth);
      expect(await readKey(SettingsKeys.transportPin), 'bluetooth');

      final reopened = await store({SettingsKeys.transportPin: 'bluetooth'});
      expect(reopened.pinnedMode, TransferMode.bluetooth);
    });

    // Pinning is also a switch — a picker that selected a transport the app
    // then went on not to use would be a lie.
    test('puts the transport into effect straight away', () async {
      final s = await store({SettingsKeys.transportMode: 'wifi'});
      await s.setPinnedMode(TransferMode.bluetooth);
      expect(s.mode, TransferMode.bluetooth);
      expect(await readKey(SettingsKeys.transportMode), 'bluetooth');
    });

    // Un-pinning is deliberately NOT a switch: there is nothing to switch to
    // until the next tap on the landing page names an intent, and rewriting
    // the effective mode here would be guessing at it.
    test('un-pinning leaves the running transport alone', () async {
      final s = await store({});
      await s.setPinnedMode(TransferMode.bluetooth);
      await s.setPinnedMode(null);
      expect(s.pinnedMode, isNull);
      expect(s.mode, TransferMode.bluetooth);
      expect(await readKey(SettingsKeys.transportPin), 'auto');
    });

    test('emits on the pin stream, null included', () async {
      final s = await store({});
      final seen = <TransferMode?>[];
      final sub = s.pinChanges.listen(seen.add);
      await s.setPinnedMode(TransferMode.guest);
      await s.setPinnedMode(null);
      await Future<void>.delayed(Duration.zero);
      await sub.cancel();
      expect(seen, [TransferMode.guest, null]);
    });

    // The side taken on a hotspot bridge means nothing once the transport
    // changes, and pinning changes it through setMode like every other path.
    test('clears any side taken on a previous bridge', () async {
      final roles = _FakeRoleStore()..setRole(SessionRole.host);
      final s = await store({}, roles: roles);
      await s.setPinnedMode(TransferMode.bluetooth);
      expect(roles.role, isNull);
    });
  });

  group('entitlement', () {
    // Demoted to automatic rather than to Bluetooth. Leaving a paid pin in
    // place would have the advisor keep short-circuiting to a transport
    // setMode then refuses — a button that visibly does nothing — while
    // rewriting it to Bluetooth would put a hand-picked value in a slot the
    // user never touched, so a later purchase would restore nothing.
    test('a paid pin falls back to automatic when unentitled', () async {
      final s = await store(
        {SettingsKeys.transportPin: 'wifi'},
        unlocked: false,
      );
      expect(s.pinnedMode, isNull);
      expect(await readKey(SettingsKeys.transportPin), 'auto');
    });

    test('a free pin is untouched', () async {
      final s = await store(
        {SettingsKeys.transportPin: 'bluetooth'},
        unlocked: false,
      );
      expect(s.pinnedMode, TransferMode.bluetooth);
    });

    test('pinning a paid transport unentitled is refused, not half-applied',
        () async {
      final s = await store({}, unlocked: false);
      await s.setPinnedMode(TransferMode.guest);
      expect(s.pinnedMode, isNull);
      expect(s.mode, isNot(TransferMode.guest));
    });
  });
}
