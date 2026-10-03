import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get_it/get_it.dart';
import 'package:tark/core/account/account_session.dart';
import 'package:tark/core/config/support_config.dart';
import 'package:tark/core/entitlement/billing_service.dart';
import 'package:tark/core/entitlement/install_identity.dart';
import 'package:tark/core/entitlement/plan_catalog.dart';
import 'package:tark/core/entitlement/premium_feature.dart';
import 'package:tark/core/entitlement/signed_entitlement.dart';
import 'package:tark/core/entitlement/subscription_gate_page.dart';
import 'package:tark/core/entitlement/subscription_remote.dart';
import 'package:tark/core/entitlement/subscription_service.dart';
import 'package:tark/core/l10n/app_localizations.dart';
import 'package:tark/core/security/app_secure_storage.dart';

import '../account/account_fakes.dart';
import 'token_factory.dart';

class _Remote implements SubscriptionRemote {
  _Remote(this.answer);
  SubscriptionFetch Function() answer;

  @override
  Future<SubscriptionFetch> fetch({
    required String installKey,
    bool fresh = false,
  }) async => answer();

  @override
  Future<SubscriptionFetch> submitBazaarPurchase({
    required String installKey,
    required String sku,
    required String purchaseToken,
  }) async => answer();
}

class _Plans implements PlanCatalog {
  @override
  Future<List<BillingPlan>> load() async => const [
    BillingPlan(sku: 'tark_premium_1m', months: 1, title: '1 month'),
    BillingPlan(sku: 'tark_premium_3m', months: 3, title: '3 months'),
  ];
}

/// Bazaar sells the plans it is asked about, except the 3-month one.
class _Billing extends UnavailableBillingService {
  const _Billing();

  @override
  Future<List<BillingPlanOffer>> offers(List<BillingPlan> plans) async => [
    for (final plan in plans)
      if (plan.months == 1) BillingPlanOffer(plan: plan, price: '50,000 Rial'),
  ];
}

void main() {
  final issued = DateTime.utc(2026, 10, 1, 12);
  final until = DateTime.utc(2026, 10, 12, 12);

  late TokenFactory factory;
  late MemoryAppSecureStorage storage;
  late String installKey;

  setUp(() async {
    factory = await TokenFactory.create();
    storage = MemoryAppSecureStorage();
    final identity = InstallIdentity(storage);
    await identity.load();
    installKey = identity.publicKey;
    GetIt.instance.registerSingleton<BillingService>(const _Billing());
    GetIt.instance.registerSingleton<PlanCatalog>(_Plans());
  });

  tearDown(() => GetIt.instance.reset());

  /// Primes a service with a stored token (fetched while "online"), then
  /// cuts the connection and moves the clock to [now].
  Future<void> prime({
    required DateTime now,
    Map<String, Object?>? payload,
    SubscriptionFetch offline = const FetchUnreachable(),
  }) async {
    var clock = issued;
    final remote = _Remote(() => offline);
    if (payload != null) {
      final raw = await factory.sign(payload);
      remote.answer = () => FetchedEntitlement(raw, bazaarChecked: true);
    }
    final service = SubscriptionService(
      storage: storage,
      identity: InstallIdentity(storage),
      verifier: EntitlementVerifier(factory.keys),
      remote: remote,
      monetized: true,
      clock: () => clock,
    );
    await service.initialize();
    if (payload != null) await service.check();
    remote.answer = () => offline;
    clock = now;
    GetIt.instance.registerSingleton<SubscriptionService>(service);
  }

  Future<void> pumpGate(WidgetTester tester, {Locale? locale}) async {
    tester.view.physicalSize = const Size(360, 740);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        locale: locale ?? const Locale('en'),
        supportedLocales: AppLocalizations.supportedLocales,
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        home: const SubscriptionGatePage(feature: PremiumFeature.selfMute),
      ),
    );
    // The check holds "checking" for a moment on purpose, and the retry
    // button breathes forever, so settle by time rather than pumpAndSettle.
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 700)),
    );
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
  }

  testWidgets('no data, offline', (tester) async {
    await tester.runAsync(() => prime(now: issued));
    await pumpGate(tester);

    expect(find.text("Let's check your subscription"), findsOneWidget);
    expect(find.textContaining("doesn't seem to be online"), findsOneWidget);
    expect(find.text(SupportConfig.email), findsOneWidget);
    expect(find.text('TRY AGAIN'), findsOneWidget);
  });

  testWidgets('expired, offline, shows the last known date', (tester) async {
    await tester.runAsync(
      () => prime(
        now: until.add(const Duration(days: 1)),
        payload: TokenFactory.payload(
          installKey: installKey,
          issuedAt: issued,
          until: until,
          autoRenewing: false,
        ),
      ),
    );
    await pumpGate(tester);

    expect(find.text('Time for a quick check'), findsOneWidget);
    expect(find.textContaining('ended on 12 October 2026'), findsOneWidget);
  });

  testWidgets('conservative mode, offline, in Persian', (tester) async {
    await tester.runAsync(
      () => prime(
        now: issued.add(const Duration(days: 4)),
        payload: TokenFactory.payload(
          installKey: installKey,
          issuedAt: issued,
          until: until,
          suspicious: true,
        ),
      ),
    );
    await pumpGate(tester, locale: const Locale('fa'));

    expect(find.text('یه سر زدن کوتاه'), findsOneWidget);
    expect(find.textContaining('۹ مهر ۱۴۰۵'), findsOneWidget);
  });

  testWidgets('server trouble never blames the connection', (tester) async {
    await tester.runAsync(
      () => prime(now: issued, offline: const FetchServiceTrouble()),
    );
    await pumpGate(tester);

    expect(find.textContaining("That's on our side"), findsOneWidget);
    expect(find.textContaining('online'), findsNothing);
  });

  testWidgets('expired and online is a plain renewal screen', (tester) async {
    await tester.runAsync(() async {
      final raw = await factory.sign(
        TokenFactory.payload(
          installKey: installKey,
          issuedAt: issued,
          until: until,
          status: 'expired',
          autoRenewing: false,
        ),
      );
      final service = SubscriptionService(
        storage: storage,
        identity: InstallIdentity(storage),
        verifier: EntitlementVerifier(factory.keys),
        remote: _Remote(() => FetchedEntitlement(raw, bazaarChecked: true)),
        monetized: true,
        clock: () => until.add(const Duration(days: 3)),
      );
      await service.initialize();
      GetIt.instance.registerSingleton<SubscriptionService>(service);
    });
    await pumpGate(tester);

    expect(find.text('Welcome back'), findsOneWidget);
    // The server's plan names with Bazaar's prices; a plan Bazaar has no
    // price for is not offered.
    expect(find.text('1 month'), findsOneWidget);
    expect(find.text('50,000 Rial'), findsOneWidget);
    expect(find.text('3 months'), findsNothing);
    expect(find.text('TRY AGAIN'), findsNothing);
  });

  testWidgets('signed out: offers sign-in where this build has it', (
    tester,
  ) async {
    await tester.runAsync(
      () => prime(now: issued, offline: const FetchSignedOut()),
    );
    GetIt.instance.registerSingleton<AccountSession>(AccountHarness().session);
    await pumpGate(tester);

    expect(find.text('Sign in to subscribe'), findsOneWidget);
    expect(find.text('SIGN IN'), findsOneWidget);
  });

  testWidgets('signed out on a build without sign-in: no dead button', (
    tester,
  ) async {
    await tester.runAsync(
      () => prime(now: issued, offline: const FetchSignedOut()),
    );
    await pumpGate(tester);

    expect(find.text('Sign in to subscribe'), findsOneWidget);
    expect(find.text('SIGN IN'), findsNothing);
  });
}
