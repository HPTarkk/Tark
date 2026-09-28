import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:tark/core/entitlement/install_identity.dart';
import 'package:tark/core/entitlement/signed_entitlement.dart';
import 'package:tark/core/entitlement/subscription_policy.dart';
import 'package:tark/core/entitlement/subscription_remote.dart';
import 'package:tark/core/entitlement/subscription_service.dart';
import 'package:tark/core/security/app_secure_storage.dart';
import 'package:tark/feature/transfer/domain/entity/transfer_mode.dart';

import 'token_factory.dart';

class _Clock {
  _Clock(this.now);
  DateTime now;
  DateTime call() => now;
}

class _Remote implements SubscriptionRemote {
  SubscriptionFetch Function() answer = () => const FetchUnreachable();
  int fetches = 0;
  Completer<void>? gate;

  @override
  Future<SubscriptionFetch> fetch({required String installKey}) async {
    fetches++;
    await gate?.future;
    return answer();
  }

  @override
  Future<SubscriptionFetch> submitBazaarPurchase({
    required String installKey,
    required String sku,
    required String purchaseToken,
  }) async => answer();
}

void main() {
  final issued = DateTime.utc(2026, 10, 1);
  final until = DateTime.utc(2026, 11, 1);

  late TokenFactory factory;
  late MemoryAppSecureStorage storage;
  late _Remote remote;
  late _Clock clock;
  late String installKey;

  setUp(() async {
    factory = await TokenFactory.create();
    storage = MemoryAppSecureStorage();
    remote = _Remote();
    clock = _Clock(issued);
    final identity = InstallIdentity(storage);
    await identity.load();
    installKey = identity.publicKey;
  });

  Future<SubscriptionService> service() async {
    final s = SubscriptionService(
      storage: storage,
      identity: InstallIdentity(storage),
      verifier: EntitlementVerifier(factory.keys),
      remote: remote,
      monetized: true,
      clock: clock.call,
    );
    await s.initialize();
    return s;
  }

  Future<String> token({
    DateTime? issuedAt,
    DateTime? end,
    String status = 'active',
    bool suspicious = false,
    bool autoRenewing = true,
  }) => factory.sign(
    TokenFactory.payload(
      installKey: installKey,
      issuedAt: issuedAt ?? issued,
      until: end ?? until,
      status: status,
      suspicious: suspicious,
      autoRenewing: autoRenewing,
    ),
  );

  test('fresh install, offline: the no-data screen', () async {
    final s = await service();
    final outcome = await s.check() as GateCouldNotCheck;
    expect(outcome.reason, CheckReason.noData);
    expect(outcome.serviceTrouble, isFalse);
  });

  test('server trouble is reported as trouble, not as offline', () async {
    remote.answer = () => const FetchServiceTrouble();
    final s = await service();
    final outcome = await s.check() as GateCouldNotCheck;
    expect(outcome.serviceTrouble, isTrue);
  });

  test('a verified purchase unlocks, and survives a restart offline', () async {
    final raw = await token();
    remote.answer = () => FetchedEntitlement(raw, bazaarChecked: true);
    final s = await service();
    expect(await s.check(), isA<GateGranted>());
    expect(s.isPremiumActive, isTrue);

    remote.answer = () => const FetchUnreachable();
    clock.now = issued.add(const Duration(days: 10));
    final relaunched = await service();
    expect(relaunched.isPremiumActive, isTrue);
    expect(remote.fetches, 1, reason: 'no refresh while far from the end');
  });

  test('expired and offline shows the last known end date', () async {
    final raw = await token(autoRenewing: false);
    remote.answer = () => FetchedEntitlement(raw, bazaarChecked: true);
    final s = await service();
    await s.check();

    remote.answer = () => const FetchUnreachable();
    clock.now = until.add(const Duration(days: 1));
    final outcome = await s.check() as GateCouldNotCheck;
    expect(outcome.reason, CheckReason.expired);
    expect(outcome.endedAt, until);
  });

  test('expired and online is the renewal screen, not an error', () async {
    final raw = await token(status: 'expired', autoRenewing: false);
    remote.answer = () => FetchedEntitlement(raw, bazaarChecked: true);
    final s = await service();
    final outcome = await s.check() as GateSubscribe;
    expect(outcome.endedAt, until);
  });

  test('winding the clock back does not extend access', () async {
    final raw = await token(autoRenewing: false);
    remote.answer = () => FetchedEntitlement(raw, bazaarChecked: true);
    final s = await service();
    await s.check();

    remote.answer = () => const FetchUnreachable();
    clock.now = until.add(const Duration(days: 2));
    expect(s.isPremiumActive, isFalse);
    clock.now = issued;
    expect(s.isPremiumActive, isFalse);

    await pumpEventQueue();
    final relaunched = await service();
    expect(relaunched.isPremiumActive, isFalse);
  });

  test('a phone whose clock runs ahead is judged by server time', () async {
    // The phone thinks it is two months later than it is.
    clock.now = issued.add(const Duration(days: 60));
    final raw = await token();
    remote.answer = () => FetchedEntitlement(raw, bazaarChecked: true);
    final s = await service();
    expect(await s.check(), isA<GateGranted>());
    expect(s.isPremiumActive, isTrue);
  });

  test('conservative mode: offline past the limit needs a check', () async {
    final raw = await token(suspicious: true);
    remote.answer = () => FetchedEntitlement(raw, bazaarChecked: true);
    final s = await service();
    await s.check();
    expect(s.isPremiumActive, isTrue);

    remote.answer = () => const FetchUnreachable();
    clock.now = issued.add(const Duration(days: 4));
    final outcome = await s.check() as GateCouldNotCheck;
    expect(outcome.reason, CheckReason.staleCheck);
    expect(outcome.lastCheckedAt, issued);
  });

  test('conservative mode refreshes at every launch', () async {
    final raw = await token(suspicious: true);
    remote.answer = () => FetchedEntitlement(raw, bazaarChecked: true);
    final s = await service();
    await s.check();
    final before = remote.fetches;

    await service();
    await pumpEventQueue();
    expect(remote.fetches, before + 1);
  });

  test('a tampered stored token is treated as no token', () async {
    final raw = await token();
    remote.answer = () => FetchedEntitlement(raw, bazaarChecked: true);
    final s = await service();
    await s.check();

    final stored = await storage.read('subscription_state');
    await storage.write(
      'subscription_state',
      stored!.replaceFirst(RegExp(r'"t":"[^"]{10}'), '"t":"AAAAAAAAAA'),
    );
    remote.answer = () => const FetchUnreachable();
    final relaunched = await service();
    expect(relaunched.entitlement, isNull);
    expect(relaunched.isPremiumActive, isFalse);
  });

  test('a reply that fails verification is not trusted', () async {
    final other = await TokenFactory.create();
    final forged = await other.sign(
      TokenFactory.payload(
        installKey: installKey,
        issuedAt: issued,
        until: until,
      ),
    );
    remote.answer = () => FetchedEntitlement(forged, bazaarChecked: true);
    final s = await service();
    final outcome = await s.check() as GateCouldNotCheck;
    expect(outcome.serviceTrouble, isTrue);
    expect(s.isPremiumActive, isFalse);
  });

  test('concurrent checks share one request', () async {
    final raw = await token();
    remote.answer = () => FetchedEntitlement(raw, bazaarChecked: true);
    remote.gate = Completer<void>();
    final s = await service();
    final first = s.check();
    final second = s.check();
    remote.gate!.complete();
    expect(await first, isA<GateGranted>());
    expect(await second, isA<GateGranted>());
    expect(remote.fetches, 1);
  });

  test('signed out is its own outcome', () async {
    remote.answer = () => const FetchSignedOut();
    final s = await service();
    expect(await s.check(), isA<GateSignInRequired>());
  });

  test('Bluetooth is free and every other transport is not', () {
    expect(TransferMode.bluetooth.requiresPremium, isFalse);
    expect(TransferMode.wifi.requiresPremium, isTrue);
    expect(TransferMode.hotspot.requiresPremium, isTrue);
    expect(TransferMode.guest.requiresPremium, isTrue);
  });
}
