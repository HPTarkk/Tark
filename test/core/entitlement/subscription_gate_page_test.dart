import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get_it/get_it.dart';
import 'package:tark/core/account/account_session.dart';
import 'package:tark/core/config/support_config.dart';
import 'package:tark/core/entitlement/billing_service.dart';
import 'package:tark/core/entitlement/install_identity.dart';
import 'package:tark/core/entitlement/license_gate.dart';
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

/// A plan list that can come back empty, then full on the next try.
class _ScriptedPlans implements PlanCatalog {
  _ScriptedPlans(this.answers);
  final List<List<BillingPlan>> answers;
  int calls = 0;

  @override
  Future<List<BillingPlan>> load() async =>
      answers[(calls++).clamp(0, answers.length - 1)];
}

/// Bazaar that can be missing, or connected but without prices.
class _ScriptedBilling extends UnavailableBillingService {
  _ScriptedBilling({required this.available, this.priced = false});
  bool available;
  bool priced;

  @override
  Future<bool> isAvailable() async => available;

  @override
  Future<List<BillingPlanOffer>> offers(List<BillingPlan> plans) async => [
    if (available && priced)
      for (final plan in plans)
        BillingPlanOffer(plan: plan, price: '50,000 Rial'),
  ];
}

class _Gate implements LicenseGate {
  const _Gate({required this.canPurchase});

  @override
  final bool canPurchase;

  @override
  bool allows(PremiumFeature feature) => true;

  @override
  Stream<void> get changes => const Stream.empty();
}

const _onePlan = [
  BillingPlan(sku: 'tark_premium_1m', months: 1, title: '1 month'),
];

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
    // Plans with Bazaar's prices; a plan Bazaar has no price for is not
    // offered. The only plan is preselected, and the pinned button names it.
    expect(find.text('1 month'), findsOneWidget);
    expect(find.text('50,000 Rial'), findsOneWidget);
    expect(find.text('3 months'), findsNothing);
    expect(find.byKey(const ValueKey('paywall-buy')), findsOneWidget);
    expect(find.text('1 month · 50,000 Rial'), findsOneWidget);
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

  group('no plans to offer says why', () {
    /// Signed in, online, never subscribed: the plain paywall.
    Future<void> online() async {
      final raw = await factory.sign(
        TokenFactory.payload(
          installKey: installKey,
          issuedAt: issued,
          status: 'none',
        ),
      );
      final service = SubscriptionService(
        storage: storage,
        identity: InstallIdentity(storage),
        verifier: EntitlementVerifier(factory.keys),
        remote: _Remote(() => FetchedEntitlement(raw, bazaarChecked: true)),
        monetized: true,
        clock: () => issued,
      );
      await service.initialize();
      GetIt.instance.registerSingleton<SubscriptionService>(service);
    }

    void use({PlanCatalog? plans, BillingService? billing, LicenseGate? gate}) {
      if (plans != null) {
        GetIt.instance.unregister<PlanCatalog>();
        GetIt.instance.registerSingleton<PlanCatalog>(plans);
      }
      if (billing != null) {
        GetIt.instance.unregister<BillingService>();
        GetIt.instance.registerSingleton<BillingService>(billing);
      }
      if (gate != null) GetIt.instance.registerSingleton<LicenseGate>(gate);
    }

    Future<void> settle(WidgetTester tester) async {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 700)),
      );
      for (var i = 0; i < 10; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
    }

    testWidgets('a build that sells nothing: free, no retry, no buy', (
      tester,
    ) async {
      await tester.runAsync(online);
      use(gate: const _Gate(canPurchase: false));
      await pumpGate(tester);

      expect(find.text("Plans aren't on sale yet"), findsOneWidget);
      expect(find.byKey(const ValueKey('paywall-plans-retry')), findsNothing);
      expect(find.byKey(const ValueKey('paywall-buy')), findsNothing);
    });

    testWidgets('the server sent no plans, and a retry brings them', (
      tester,
    ) async {
      await tester.runAsync(online);
      final plans = _ScriptedPlans([const [], _onePlan]);
      use(
        plans: plans,
        billing: _ScriptedBilling(available: true, priced: true),
        gate: const _Gate(canPurchase: true),
      );
      await pumpGate(tester);

      expect(find.text("Couldn't load the plans"), findsOneWidget);
      expect(find.byKey(const ValueKey('paywall-buy')), findsNothing);

      final retry = find.byKey(const ValueKey('paywall-plans-retry'));
      await tester.ensureVisible(retry);
      await tester.pump();
      await tester.tap(retry);
      await tester.pump();
      expect(find.text('CHECKING'), findsOneWidget);
      await settle(tester);

      expect(plans.calls, 2);
      expect(find.text("Couldn't load the plans"), findsNothing);
      expect(find.text('50,000 Rial'), findsOneWidget);
      expect(find.byKey(const ValueKey('paywall-buy')), findsOneWidget);
    });

    testWidgets('Bazaar missing or signed out', (tester) async {
      await tester.runAsync(online);
      use(
        plans: _ScriptedPlans([_onePlan]),
        billing: _ScriptedBilling(available: false),
      );
      await pumpGate(tester);

      expect(find.text("Cafe Bazaar isn't answering"), findsOneWidget);
      expect(find.text('TRY AGAIN'), findsOneWidget);
    });

    testWidgets('Bazaar has no prices for the plans, in Persian', (
      tester,
    ) async {
      await tester.runAsync(online);
      use(
        plans: _ScriptedPlans([_onePlan]),
        billing: _ScriptedBilling(available: true),
      );
      await pumpGate(tester, locale: const Locale('fa'));

      expect(find.text('قیمت‌ها هنوز آماده نیست'), findsOneWidget);
      expect(find.text('دوباره امتحان کن'), findsOneWidget);
    });
  });
}
