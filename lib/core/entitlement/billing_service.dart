import 'package:equatable/equatable.dart';

/// A plan as the backend sells it (`GET /subscription/plans`). Which plans
/// exist, their order and their names all come from the server, so a plan
/// is added or retired there without an app update. The length is part of
/// the product id (`tark_premium_<months>m`), which must match the Bazaar
/// panel. The one exception is [testSku], a 5-minute product that only a
/// test server lists.
class BillingPlan extends Equatable {
  const BillingPlan({
    required this.sku,
    required this.months,
    required this.title,
  });

  final String sku;

  /// 0 for the test plan, which is minutes long.
  final int months;

  /// The plan's name in the language the server was asked for ("3 months",
  /// "سه ماهه").
  final String title;

  static final _skuPattern = RegExp(r'^tark_premium_([1-9][0-9]?)m$');

  /// The Bazaar product that renews every 5 minutes, for trying purchases
  /// and renewals. Shown only when the server's plan list includes it, and
  /// the production server never lists it.
  static const testSku = 'TEST_SUB';

  /// Months in a plan id, or null for anything that is not one of ours.
  static int? monthsOf(String sku) {
    final match = _skuPattern.firstMatch(sku);
    return match == null ? null : int.parse(match.group(1)!);
  }

  static bool isPlanSku(String sku) => sku == testSku || monthsOf(sku) != null;

  /// A plan from one entry of the server's list, or null when malformed.
  static BillingPlan? fromJson(Object? json) {
    if (json is! Map) return null;
    final sku = json['sku'];
    final title = json['title'];
    if (sku is! String || title is! String || title.trim().isEmpty) {
      return null;
    }
    final months = sku == testSku ? 0 : monthsOf(sku);
    if (months == null) return null;
    return BillingPlan(sku: sku, months: months, title: title.trim());
  }

  @override
  List<Object?> get props => [sku, months, title];
}

/// Outcome of a purchase attempt, kept deliberately coarse: the UI only ever
/// needs to distinguish "unlocked", "user backed out", and "something broke".
sealed class PurchaseResult {
  const PurchaseResult();
}

/// The store says the purchase went through. That is a claim, not access:
/// [purchase] goes to the server, which verifies it with Bazaar and answers
/// with the signed entitlement.
class PurchaseSuccess extends PurchaseResult {
  const PurchaseSuccess(this.purchase);
  final StorePurchase purchase;
}

/// A purchase as the store reports it: which product, and the token the
/// server verifies it with. [sku] may be a plan no longer on sale; the
/// server still accepts it.
class StorePurchase {
  const StorePurchase({required this.sku, required this.purchaseToken});

  final String sku;
  final String purchaseToken;
}

class PurchaseCancelled extends PurchaseResult {
  const PurchaseCancelled();
}

class PurchaseFailed extends PurchaseResult {
  const PurchaseFailed(this.message);
  final String message;
}

/// A plan as the store currently sells it.
///
/// [price] is whatever formatted string the store returns — the app never
/// composes or hardcodes a price. That is deliberate: prices live in the
/// business plan and in each store's console, and a number baked into the
/// binary would go stale the first time you run a discount.
class BillingPlanOffer {
  const BillingPlanOffer({required this.plan, required this.price});

  final BillingPlan plan;
  final String price;
}

/// Store-agnostic billing port. Bazaar (Poolakey) gets its own
/// implementation behind this; nothing above this line knows which store
/// the running build talks to.
///
/// Implementations only talk to the store. Whether a purchase counts is the
/// server's call (see SubscriptionService.submitBazaarPurchase): nothing the
/// store SDK returns on the phone is trusted on its own.
abstract interface class BillingService {
  /// Whether a store SDK is present and connected in this build.
  Future<bool> isAvailable();

  /// Live prices from the store for [plans], in their order; a plan the
  /// store does not sell is left out. Empty when billing is unavailable.
  Future<List<BillingPlanOffer>> offers(List<BillingPlan> plans);

  Future<PurchaseResult> purchase(BillingPlan plan);

  /// Re-reads purchases the store account already owns — the "restore" path
  /// after a reinstall or device change. Empty when nothing is owned.
  Future<List<StorePurchase>> restore();
}

/// Stand-in for every build without a store SDK: desktop, web, and Android
/// until the Bazaar channel lands.
///
/// Reports unavailable rather than throwing, so callers exercise the same
/// "no purchase path" branch they will hit on desktop for real.
///
/// Bound by BillingModule in di_config.dart rather than annotated here —
/// which implementation wins is a per-platform decision.
class UnavailableBillingService implements BillingService {
  const UnavailableBillingService();

  @override
  Future<bool> isAvailable() async => false;

  @override
  Future<List<BillingPlanOffer>> offers(List<BillingPlan> plans) async =>
      const [];

  @override
  Future<PurchaseResult> purchase(BillingPlan plan) async =>
      const PurchaseFailed('billing_unavailable');

  @override
  Future<List<StorePurchase>> restore() async => const [];
}
