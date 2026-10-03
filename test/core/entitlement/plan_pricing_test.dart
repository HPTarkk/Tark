import 'package:flutter_test/flutter_test.dart';
import 'package:tark/core/entitlement/billing_service.dart';
import 'package:tark/core/entitlement/plan_pricing.dart';

BillingPlanOffer offer(int months, String price) => BillingPlanOffer(
  plan: BillingPlan(
    sku: months == 0 ? 'TEST_SUB' : 'tark_premium_${months}m',
    months: months,
    title: 'plan $months',
  ),
  price: price,
);

void main() {
  group('StorePrice', () {
    test('reads Latin digits and keeps the words around them', () {
      final price = StorePrice.parse('2,690,000 Rial')!;
      expect(price.amount, 2690000);
      expect(price.format(896700), '896,700 Rial');
    });

    test('reads Persian digits and writes them back', () {
      final price = StorePrice.parse('۲۶۹٬۰۰۰ تومان')!;
      expect(price.amount, 269000);
      expect(price.format(89700), '۸۹٬۷۰۰ تومان');
    });

    test('leaves anything that is not one number alone', () {
      expect(StorePrice.parse('free'), isNull);
      expect(StorePrice.parse('2 for 100'), isNull);
      expect(StorePrice.parse('0 Rial'), isNull);
    });
  });

  group('PlanPricing', () {
    test('works out monthly prices, savings and the best value', () {
      final plans = PlanPricing.of([
        offer(1, '100,000 Rial'),
        offer(3, '270,000 Rial'),
        offer(12, '840,000 Rial'),
      ]);
      expect(plans.map((p) => p.perMonth), [
        null,
        '90,000 Rial',
        '70,000 Rial',
      ]);
      expect(plans.map((p) => p.savingPercent), [null, 10, 30]);
      expect(plans.map((p) => p.bestValue), [false, false, true]);
      expect(PlanPricing.preselect(plans), 'tark_premium_12m');
    });

    test('no saving across different currencies or below 3%', () {
      final plans = PlanPricing.of([
        offer(1, '100,000 Rial'),
        offer(3, '30,000 Toman'),
        offer(6, '590,000 Rial'),
      ]);
      expect(plans[1].savingPercent, isNull);
      expect(plans[2].savingPercent, isNull);
      expect(plans.any((p) => p.bestValue), isFalse);
      expect(PlanPricing.preselect(plans), 'tark_premium_6m');
    });

    test('the test plan gets no monthly price', () {
      final plans = PlanPricing.of([offer(0, '1,000 Rial')]);
      expect(plans.single.perMonth, isNull);
      expect(PlanPricing.preselect(plans), 'TEST_SUB');
      expect(PlanPricing.preselect(const []), isNull);
    });
  });
}
