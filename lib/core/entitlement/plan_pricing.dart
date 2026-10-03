import 'billing_service.dart';

/// A store price string ("۲۶۹٬۰۰۰ تومان", "2,690,000 Rial") split into its
/// amount and the text around it, so the plans screen can show a monthly
/// price and a saving in the store's own style. Bazaar only hands over the
/// formatted string, so anything that does not read as one whole number is
/// left alone and the screen shows the price as it came.
class StorePrice {
  const StorePrice._(
    this.amount, {
    required this.persianDigits,
    required this.separator,
    required this.prefix,
    required this.suffix,
  });

  final int amount;
  final bool persianDigits;
  final String separator;
  final String prefix;
  final String suffix;

  static final _number = RegExp(
    r'[0-9۰-۹٠-٩](?:[0-9۰-۹٠-٩,٬.   ]*[0-9۰-۹٠-٩])?',
  );

  static StorePrice? parse(String text) {
    final matches = _number.allMatches(text).toList();
    if (matches.length != 1) return null;
    final match = matches.single;
    final raw = match.group(0)!;
    final digits = StringBuffer();
    String? separator;
    for (final rune in raw.runes) {
      final digit = _digitValue(rune);
      if (digit != null) {
        digits.write(digit);
      } else {
        separator ??= String.fromCharCode(rune);
      }
    }
    final amount = int.tryParse(digits.toString());
    if (amount == null || amount <= 0) return null;
    return StorePrice._(
      amount,
      persianDigits: RegExp('[۰-۹٠-٩]').hasMatch(raw),
      separator: separator ?? ',',
      prefix: text.substring(0, match.start),
      suffix: text.substring(match.end),
    );
  }

  static int? _digitValue(int rune) {
    if (rune >= 0x30 && rune <= 0x39) return rune - 0x30;
    if (rune >= 0x6F0 && rune <= 0x6F9) return rune - 0x6F0;
    if (rune >= 0x660 && rune <= 0x669) return rune - 0x660;
    return null;
  }

  /// [value] written the way this price was: same digits, same grouping,
  /// same currency words around it.
  String format(int value) {
    final plain = value.toString();
    final grouped = StringBuffer();
    for (var i = 0; i < plain.length; i++) {
      if (i > 0 && (plain.length - i) % 3 == 0) grouped.write(separator);
      grouped.write(plain[i]);
    }
    var number = grouped.toString();
    if (persianDigits) {
      number = String.fromCharCodes(
        number.runes.map((r) => r >= 0x30 && r <= 0x39 ? r - 0x30 + 0x6F0 : r),
      );
    }
    return '$prefix$number$suffix';
  }
}

/// One offer with what the plans screen says about it beyond its price.
class PlanPricing {
  const PlanPricing({
    required this.offer,
    this.perMonth,
    this.savingPercent,
    this.bestValue = false,
  });

  final BillingPlanOffer offer;

  /// The price spread over the plan's months, for plans longer than one.
  final String? perMonth;

  /// How much cheaper a month is than on the one-month plan, when there is
  /// one to compare with and the difference is worth saying.
  final int? savingPercent;

  /// The plan with the biggest saving; the screen preselects it.
  final bool bestValue;

  String get sku => offer.plan.sku;

  /// Works out monthly prices and savings for [offers], in their order.
  static List<PlanPricing> of(List<BillingPlanOffer> offers) {
    final prices = {
      for (final offer in offers) offer.plan.sku: StorePrice.parse(offer.price),
    };
    // Savings only compare like with like: the same currency words.
    StorePrice? monthly;
    for (final offer in offers) {
      if (offer.plan.months == 1) monthly = prices[offer.plan.sku];
    }
    final out = <PlanPricing>[];
    int? bestSaving;
    String? bestSku;
    for (final offer in offers) {
      final price = prices[offer.plan.sku];
      final months = offer.plan.months;
      String? perMonth;
      int? saving;
      if (price != null && months > 1) {
        final exact = price.amount / months;
        perMonth = price.format(_roundForDisplay(exact));
        final base = monthly;
        if (base != null &&
            base.suffix == price.suffix &&
            base.prefix == price.prefix) {
          final percent = ((1 - exact / base.amount) * 100).round();
          if (percent >= 3) saving = percent;
        }
      }
      if (saving != null && (bestSaving == null || saving > bestSaving)) {
        bestSaving = saving;
        bestSku = offer.plan.sku;
      }
      out.add(
        PlanPricing(offer: offer, perMonth: perMonth, savingPercent: saving),
      );
    }
    return [
      for (final p in out)
        p.sku == bestSku
            ? PlanPricing(
                offer: p.offer,
                perMonth: p.perMonth,
                savingPercent: p.savingPercent,
                bestValue: true,
              )
            : p,
    ];
  }

  /// The plan to select when the screen opens: the best value, else the
  /// longest real plan, else the first.
  static String? preselect(List<PlanPricing> plans) {
    if (plans.isEmpty) return null;
    for (final p in plans) {
      if (p.bestValue) return p.sku;
    }
    var pick = plans.first;
    for (final p in plans) {
      if (p.offer.plan.months > pick.offer.plan.months) pick = p;
    }
    return pick.sku;
  }

  /// Monthly prices are a guide, so they read cleanly: whole thousands for
  /// big amounts, whole hundreds for middling ones.
  static int _roundForDisplay(double value) {
    if (value >= 100000) return (value / 1000).round() * 1000;
    if (value >= 10000) return (value / 100).round() * 100;
    return value.round();
  }
}
