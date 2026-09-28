/// A purchasable plan. Monthly and yearly only: those are the subscription
/// periods Bazaar offers. The [sku] values must match the product ids
/// registered in each store's developer console before billing can ship.
enum BillingPlan {
  monthly(sku: 'tark_premium_1m', months: 1),
  yearly(sku: 'tark_premium_12m', months: 12);

  const BillingPlan({required this.sku, required this.months});

  /// Also the `sku` enum in backend/api/openapi.yaml — change both together.
  final String sku;
  final int months;

  static BillingPlan? forSku(String sku) {
    for (final plan in BillingPlan.values) {
      if (plan.sku == sku) return plan;
    }
    return null;
  }
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

/// A purchase as the store reports it: which plan, and the token the server
/// verifies it with.
class StorePurchase {
  const StorePurchase({required this.plan, required this.purchaseToken});

  final BillingPlan plan;
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

  /// Live prices from the store, in plan order. Empty when billing is
  /// unavailable — the paywall then shows plan names without prices rather
  /// than inventing them.
  Future<List<BillingPlanOffer>> offers();

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
  Future<List<BillingPlanOffer>> offers() async => const [];

  @override
  Future<PurchaseResult> purchase(BillingPlan plan) async =>
      const PurchaseFailed('billing_unavailable');

  @override
  Future<List<StorePurchase>> restore() async => const [];
}
