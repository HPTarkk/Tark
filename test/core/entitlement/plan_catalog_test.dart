import 'package:flutter_test/flutter_test.dart';
import 'package:tark/core/entitlement/billing_service.dart';
import 'package:tark/core/entitlement/plan_catalog.dart';
import 'package:tark/core/network/api_failure.dart';
import 'package:tark/core/network/service_api.dart';

import '../account/account_fakes.dart';

void main() {
  late FakeServiceClient server;
  late String language;
  late PlanCatalog catalog;

  ApiOk plans(List<Object?> list) => ApiOk(200, {'plans': list});

  setUp(() {
    server = FakeServiceClient();
    language = 'fa';
    catalog = PlanCatalog(server, language: () => language);
  });

  test('the server\'s plans, in its order, in the app\'s language', () async {
    server.handler = (_) async => plans([
      {'sku': 'tark_premium_1m', 'months': 1, 'days': 30, 'title': 'یک ماهه'},
      {'sku': 'tark_premium_3m', 'months': 3, 'days': 90, 'title': 'سه ماهه'},
      {'sku': 'tark_premium_12m', 'months': 12, 'title': 'یک ساله'},
    ]);
    final loaded = await catalog.load();
    expect(loaded.map((p) => p.sku), [
      'tark_premium_1m',
      'tark_premium_3m',
      'tark_premium_12m',
    ]);
    expect(loaded[1].title, 'سه ماهه');
    expect(loaded[1].months, 3);
    final request = server.requests.single;
    expect(request.path, '/subscription/plans');
    expect(request.headers['Accept-Language'], 'fa');
  });

  test('malformed and duplicate entries are dropped', () async {
    server.handler = (_) async => plans([
      {'sku': 'tark_premium_1m', 'title': '1 month'},
      {'sku': 'tark_premium_1m', 'title': 'again'},
      {'sku': 'someone_else', 'title': 'x'},
      {'sku': 'tark_premium_6m', 'title': ' '},
      {'sku': 'tark_premium_6m'},
      'nonsense',
    ]);
    final loaded = await catalog.load();
    expect(loaded, [
      const BillingPlan(sku: 'tark_premium_1m', months: 1, title: '1 month'),
    ]);
  });

  test('kept per language; a failure is not kept', () async {
    server.handler = (_) async =>
        const ApiTransportFailure(NetworkUnreachable('offline'));
    expect(await catalog.load(), isEmpty);

    server.handler = (request) async => plans([
      {
        'sku': 'tark_premium_1m',
        'title': request.headers['Accept-Language'] == 'fa'
            ? 'یک ماهه'
            : '1 month',
      },
    ]);
    expect((await catalog.load()).single.title, 'یک ماهه');
    expect((await catalog.load()).single.title, 'یک ماهه');
    expect(server.requests, hasLength(2));

    language = 'en';
    expect((await catalog.load()).single.title, '1 month');
    expect(server.requests, hasLength(3));
  });

  test('plan ids carry their length', () {
    expect(BillingPlan.monthsOf('tark_premium_6m'), 6);
    expect(BillingPlan.monthsOf('tark_premium_12m'), 12);
    expect(BillingPlan.monthsOf('tark_premium_0m'), isNull);
    expect(BillingPlan.monthsOf('comp'), isNull);
    expect(BillingPlan.monthsOf('tark_premium_1y'), isNull);
  });
}
