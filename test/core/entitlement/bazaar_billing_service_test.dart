import 'dart:async';

import 'package:fake_async/fake_async.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tark/core/entitlement/bazaar_billing_service.dart';
import 'package:tark/core/entitlement/billing_service.dart';

const _channel = MethodChannel('tark/bazaar_billing');

/// Stands in for BazaarBillingHandler.kt: each method answers from a
/// function the test sets, and every call is recorded.
class _Bazaar {
  final calls = <MethodCall>[];
  final answers = <String, FutureOr<Object?> Function(MethodCall call)>{
    'connect': (_) => true,
  };

  void install() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_channel, (call) async {
          calls.add(call);
          final answer = answers[call.method];
          if (answer == null) throw MissingPluginException();
          return answer(call);
        });
  }

  int count(String method) => calls.where((c) => c.method == method).length;
}

Map<String, Object?> _purchase(
  String sku,
  String token, {
  int time = 0,
  String state = 'PURCHASED',
}) => {
  'orderId': 'order-$token',
  'purchaseToken': token,
  'productId': sku,
  'purchaseState': state,
  'purchaseTime': time,
};

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late _Bazaar bazaar;
  late BazaarBillingService billing;

  setUp(() {
    bazaar = _Bazaar()..install();
    billing = BazaarBillingService();
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_channel, null);
  });

  group('connection', () {
    test('available when Bazaar binds', () async {
      expect(await billing.isAvailable(), isTrue);
    });

    test('unavailable when Bazaar refuses, is missing, or hangs', () async {
      bazaar.answers['connect'] = (_) => false;
      expect(await billing.isAvailable(), isFalse);

      bazaar.answers['connect'] = (_) =>
          throw PlatformException(code: 'failed');
      expect(await billing.isAvailable(), isFalse);

      bazaar.answers.remove('connect');
      expect(await billing.isAvailable(), isFalse);
    });

    test('a hung bind gives up after the timeout', () {
      fakeAsync((async) {
        bazaar.answers['connect'] = (_) => Completer<bool>().future;
        bool? available;
        billing.isAvailable().then((value) => available = value);
        async.elapse(BazaarBillingService.connectTimeout);
        async.flushMicrotasks();
        expect(available, isFalse);
      });
    });

    test('the build-time RSA key goes to Poolakey with the bind', () async {
      await BazaarBillingService(rsaKey: 'MIIB-test').isAvailable();
      await billing.isAvailable();
      final keys = [
        for (final call in bazaar.calls)
          if (call.method == 'connect') (call.arguments as Map)['rsaKey'],
      ];
      expect(keys, ['MIIB-test', '']);
    });

    test('concurrent callers share one bind', () async {
      final gate = Completer<bool>();
      bazaar.answers['connect'] = (_) => gate.future;
      final both = Future.wait([billing.isAvailable(), billing.isAvailable()]);
      await pumpEventQueue();
      gate.complete(true);
      expect(await both, [true, true]);
      expect(bazaar.count('connect'), 1);
    });
  });

  group('offers', () {
    test('Bazaar prices in plan order, unsold plans left out', () async {
      bazaar.answers['skuDetails'] = (_) => [
        {'sku': 'tark_premium_12m', 'price': '۴۰۰٬۰۰۰ ریال'},
        {'sku': 'tark_premium_1m', 'price': '۵۰٬۰۰۰ ریال'},
        {'sku': 'someone_else', 'price': '1'},
        {'sku': 'tark_premium_6m', 'price': ''},
      ];
      final offers = await billing.offers();
      expect(offers.map((o) => o.plan), [
        BillingPlan.monthly,
        BillingPlan.yearly,
      ]);
      expect(offers.first.price, '۵۰٬۰۰۰ ریال');
      final asked = bazaar.calls.firstWhere((c) => c.method == 'skuDetails');
      expect((asked.arguments as Map)['skus'], [
        for (final plan in BillingPlan.values) plan.sku,
      ]);
    });

    test('empty when Bazaar is unavailable or the query fails', () async {
      bazaar.answers['skuDetails'] = (_) =>
          throw PlatformException(code: 'failed');
      expect(await billing.offers(), isEmpty);

      bazaar.answers['connect'] = (_) => false;
      expect(await billing.offers(), isEmpty);
    });
  });

  group('purchase', () {
    test('success hands back the plan and token', () async {
      bazaar.answers['subscribe'] = (call) =>
          _purchase((call.arguments as Map)['sku'] as String, 'tok-1');
      final result = await billing.purchase(BillingPlan.monthly);
      expect(result, isA<PurchaseSuccess>());
      final purchase = (result as PurchaseSuccess).purchase;
      expect(purchase.plan, BillingPlan.monthly);
      expect(purchase.purchaseToken, 'tok-1');
    });

    test('backing out is a cancel, not a failure', () async {
      bazaar.answers['subscribe'] = (_) =>
          throw PlatformException(code: 'cancelled');
      expect(
        await billing.purchase(BillingPlan.monthly),
        isA<PurchaseCancelled>(),
      );
    });

    test('Bazaar errors surface as failures with their code', () async {
      bazaar.answers['subscribe'] = (_) =>
          throw PlatformException(code: 'flow_failed');
      final result = await billing.purchase(BillingPlan.monthly);
      expect((result as PurchaseFailed).message, 'flow_failed');
    });

    test('no checkout when Bazaar is unavailable', () async {
      bazaar.answers['connect'] = (_) => false;
      final result = await billing.purchase(BillingPlan.monthly);
      expect((result as PurchaseFailed).message, 'billing_unavailable');
      expect(bazaar.count('subscribe'), 0);
    });

    test(
      'a purchase for another product or without a token is refused',
      () async {
        bazaar.answers['subscribe'] = (_) => _purchase('tark_premium_12m', 't');
        expect(
          (await billing.purchase(BillingPlan.monthly) as PurchaseFailed)
              .message,
          'unexpected_purchase',
        );

        bazaar.answers['subscribe'] = (_) => _purchase('tark_premium_1m', '');
        expect(
          await billing.purchase(BillingPlan.monthly),
          isA<PurchaseFailed>(),
        );
      },
    );

    test(
      'a second tap while checkout is open does not start another',
      () async {
        final checkout = Completer<Object?>();
        bazaar.answers['subscribe'] = (_) => checkout.future;
        final first = billing.purchase(BillingPlan.monthly);
        await pumpEventQueue();
        final second = await billing.purchase(BillingPlan.yearly);
        expect((second as PurchaseFailed).message, 'purchase_in_progress');
        checkout.complete(_purchase('tark_premium_1m', 'tok'));
        expect(await first, isA<PurchaseSuccess>());
        expect(bazaar.count('subscribe'), 1);

        // And the lock is released afterwards.
        bazaar.answers['subscribe'] = (_) =>
            _purchase('tark_premium_12m', 't2');
        expect(
          await billing.purchase(BillingPlan.yearly),
          isA<PurchaseSuccess>(),
        );
      },
    );
  });

  group('restore', () {
    test('our plans only, newest first, each token once', () async {
      bazaar.answers['subscribedProducts'] = (_) => [
        _purchase('tark_premium_1m', 'old', time: 100),
        _purchase('someone_else', 'foreign', time: 999),
        _purchase('tark_premium_12m', 'new', time: 300),
        _purchase('tark_premium_12m', 'new', time: 300),
        _purchase('tark_premium_1m', '', time: 500),
        _purchase('tark_premium_1m', 'refunded', time: 200, state: 'REFUNDED'),
      ];
      final owned = await billing.restore();
      expect(owned.map((p) => p.purchaseToken), ['new', 'refunded', 'old']);
      expect(owned.first.plan, BillingPlan.yearly);
    });

    test('empty when Bazaar is unavailable or the query fails', () async {
      bazaar.answers['subscribedProducts'] = (_) =>
          throw PlatformException(code: 'not_connected');
      expect(await billing.restore(), isEmpty);

      bazaar.answers['connect'] = (_) => false;
      expect(await billing.restore(), isEmpty);
    });
  });
}
