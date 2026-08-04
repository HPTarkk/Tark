import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:tark/core/entitlement/entitlement.dart';
import 'package:tark/core/entitlement/entitlement_store_impl.dart';
import 'package:tark/core/entitlement/trial_policy.dart';
import 'package:tark/feature/transfer/domain/entity/transfer_mode.dart';

/// Movable clock, so the 90-day trial can be exercised in milliseconds.
class _Clock {
  _Clock(this.now);
  DateTime now;
  DateTime call() => now;
}

Future<EntitlementStoreImpl> _store(_Clock clock) async {
  final store = EntitlementStoreImpl.withClock(
    await SharedPreferences.getInstance(),
    clock.call,
  );
  await store.initialize();
  return store;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final start = DateTime.utc(2026, 1, 1);

  setUp(() => SharedPreferences.setMockInitialValues({}));

  group('trial', () {
    test('first launch starts the trial and unlocks premium', () async {
      final store = await _store(_Clock(start));

      expect(store.current.source, EntitlementSource.trial);
      expect(store.isPremiumActive, isTrue);
    });

    test('trial lapses once its length has passed', () async {
      final clock = _Clock(start);
      final first = await _store(clock);
      expect(first.isPremiumActive, isTrue);

      clock.now = start.add(TrialPolicy.length).add(const Duration(days: 1));
      final relaunched = await _store(clock);

      expect(relaunched.current.source, EntitlementSource.trial);
      expect(relaunched.isPremiumActive, isFalse);
    });

    test('winding the device clock back does not extend the trial', () async {
      final clock = _Clock(start);
      await _store(clock);

      // Let the trial run out, then "discover" the trick and set the date
      // back a year. The water mark persisted at expiry must win.
      clock.now = start.add(TrialPolicy.length).add(const Duration(days: 1));
      await _store(clock);

      clock.now = start.subtract(const Duration(days: 365));
      final cheated = await _store(clock);

      expect(cheated.isPremiumActive, isFalse);
    });

    test('a trial already running is not restarted by a relaunch', () async {
      final clock = _Clock(start);
      final first = await _store(clock);
      final firstExpiry = first.current.expiresAt;

      clock.now = start.add(const Duration(days: 10));
      final second = await _store(clock);

      expect(second.current.expiresAt, firstExpiry);
    });
  });

  group('purchases', () {
    test('a granted purchase survives a relaunch and outranks the trial',
        () async {
      final clock = _Clock(start);
      final first = await _store(clock);
      await first.grant(
        Entitlement(
          source: EntitlementSource.bazaar,
          expiresAt: start.add(const Duration(days: 365)),
        ),
      );

      // Well past when the trial alone would have lapsed.
      clock.now = start.add(TrialPolicy.length).add(const Duration(days: 30));
      final relaunched = await _store(clock);

      expect(relaunched.current.source, EntitlementSource.bazaar);
      expect(relaunched.isPremiumActive, isTrue);
    });

    test('a lifetime purchase never expires', () async {
      final clock = _Clock(start);
      final store = await _store(clock);
      await store.grant(
        const Entitlement(source: EntitlementSource.bazaar),
      );

      clock.now = start.add(const Duration(days: 4000));

      expect(store.current.isLifetime, isTrue);
      expect(store.isPremiumActive, isTrue);
    });

    test('revoking drops to free without handing back a fresh trial',
        () async {
      final clock = _Clock(start);
      final first = await _store(clock);
      await first.grant(const Entitlement(source: EntitlementSource.bazaar));
      await first.revoke();

      expect(first.isPremiumActive, isFalse);

      // The refund must not read as "never trialled" on the next launch.
      clock.now = start.add(TrialPolicy.length).add(const Duration(days: 1));
      final relaunched = await _store(clock);

      expect(relaunched.isPremiumActive, isFalse);
    });
  });

  group('transport tiers', () {
    test('Bluetooth is free and every other transport is not', () {
      expect(TransferMode.bluetooth.requiresPremium, isFalse);
      expect(TransferMode.wifi.requiresPremium, isTrue);
      expect(TransferMode.hotspot.requiresPremium, isTrue);
      expect(TransferMode.guest.requiresPremium, isTrue);
    });
  });
}
