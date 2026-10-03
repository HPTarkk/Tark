import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get_it/get_it.dart';
import 'package:tark/core/entitlement/install_identity.dart';
import 'package:tark/core/entitlement/signed_entitlement.dart';
import 'package:tark/core/entitlement/subscription_remote.dart';
import 'package:tark/core/entitlement/subscription_service.dart';
import 'package:tark/core/l10n/app_localizations.dart';
import 'package:tark/core/security/app_secure_storage.dart';
import 'package:tark/feature/account/api/account_api.dart';

import '../../core/entitlement/token_factory.dart';

class _Remote implements SubscriptionRemote {
  _Remote(this.answer);
  SubscriptionFetch Function() answer;

  @override
  Future<SubscriptionFetch> fetch({required String installKey}) async =>
      answer();

  @override
  Future<SubscriptionFetch> submitBazaarPurchase({
    required String installKey,
    required String sku,
    required String purchaseToken,
  }) async => answer();
}

void main() {
  final issued = DateTime.utc(2026, 10, 1, 12);
  final until = DateTime.utc(2026, 12, 30, 12);

  late TokenFactory factory;
  late MemoryAppSecureStorage storage;
  late String installKey;

  setUp(() async {
    factory = await TokenFactory.create();
    storage = MemoryAppSecureStorage();
    final identity = InstallIdentity(storage);
    await identity.load();
    installKey = identity.publicKey;
  });

  tearDown(() => GetIt.instance.reset());

  /// A service whose server answers with [payload] (or [answer]).
  Future<void> serve({
    Map<String, Object?>? payload,
    String? planTitle,
    SubscriptionFetch? answer,
    String sku = 'tark_premium_3m',
  }) async {
    final SubscriptionFetch reply;
    if (payload != null) {
      payload['sku'] = payload['st'] == 'none' ? null : sku;
      reply = FetchedEntitlement(
        await factory.sign(payload),
        bazaarChecked: true,
        planTitle: planTitle,
      );
    } else {
      reply = answer!;
    }
    final service = SubscriptionService(
      storage: storage,
      identity: InstallIdentity(storage),
      verifier: EntitlementVerifier(factory.keys),
      remote: _Remote(() => reply),
      monetized: true,
      clock: () => issued,
    );
    await service.initialize();
    GetIt.instance.registerSingleton<SubscriptionService>(service);
  }

  Future<void> pumpPage(WidgetTester tester) async {
    tester.view.physicalSize = const Size(420, 1200);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        locale: const Locale('en'),
        supportedLocales: AppLocalizations.supportedLocales,
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        home: SubscriptionPage.buildPage(),
      ),
    );
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 50)),
    );
    await tester.pump(const Duration(seconds: 1));
  }

  testWidgets('a running plan: name, renewal date, Bazaar, manage', (
    tester,
  ) async {
    await tester.runAsync(
      () => serve(
        payload: TokenFactory.payload(
          installKey: installKey,
          issuedAt: issued,
          until: until,
        ),
        planTitle: '3 months',
      ),
    );
    await pumpPage(tester);

    expect(find.text('Your subscription'), findsOneWidget);
    expect(find.text('PREMIUM'), findsOneWidget);
    expect(find.text('3 months'), findsOneWidget);
    expect(find.text('Renews on 30 December 2026'), findsOneWidget);
    expect(find.text('Paid through Cafe Bazaar'), findsOneWidget);
    expect(find.text('OPEN BAZAAR'), findsOneWidget);
    expect(find.text('RENEW'), findsNothing);
  });

  testWidgets('auto-renew off says when it ends', (tester) async {
    await tester.runAsync(
      () => serve(
        payload: TokenFactory.payload(
          installKey: installKey,
          issuedAt: issued,
          until: until,
          autoRenewing: false,
        ),
      ),
    );
    await pumpPage(tester);

    // No title from the server: named from the plan id.
    expect(find.text('3 months'), findsOneWidget);
    expect(
      find.text('Ends on 30 December 2026. Auto-renew is off.'),
      findsOneWidget,
    );
  });

  testWidgets('an ended plan offers renewal', (tester) async {
    await tester.runAsync(
      () => serve(
        payload: TokenFactory.payload(
          installKey: installKey,
          issuedAt: issued,
          status: 'expired',
          until: DateTime.utc(2026, 9, 20),
          autoRenewing: false,
        ),
        sku: 'tark_premium_12m',
      ),
    );
    await pumpPage(tester);

    expect(find.text('1 year'), findsOneWidget);
    expect(find.text('Ended on 20 September 2026'), findsOneWidget);
    expect(find.text('RENEW'), findsOneWidget);
    expect(find.text('PREMIUM'), findsNothing);
    expect(find.text('OPEN BAZAAR'), findsNothing);
  });

  testWidgets('never subscribed: the plans, and no card', (tester) async {
    await tester.runAsync(
      () => serve(
        payload: TokenFactory.payload(
          installKey: installKey,
          issuedAt: issued,
          status: 'none',
        ),
      ),
    );
    await pumpPage(tester);

    expect(find.text('No subscription yet'), findsOneWidget);
    expect(find.text('SEE PLANS'), findsOneWidget);
    expect(find.byKey(const ValueKey('subscription-card')), findsNothing);
  });

  testWidgets('offline says the page shows the latest known', (tester) async {
    await tester.runAsync(() => serve(answer: const FetchUnreachable()));
    await pumpPage(tester);

    expect(
      find.text("Couldn't reach Tark just now, so this is the latest we know."),
      findsOneWidget,
    );
  });
}
