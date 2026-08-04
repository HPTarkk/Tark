import 'entitlement.dart';

/// A purchasable plan, mirroring the B2C table in the business plan. The
/// [sku] values must match the product ids registered in each store's
/// developer console before billing can ship.
enum BillingPlan {
  monthly(sku: 'tark_premium_1m', months: 1, subscription: true),
  sixMonth(sku: 'tark_premium_6m', months: 6, subscription: true),
  yearly(sku: 'tark_premium_12m', months: 12, subscription: true),
  lifetime(sku: 'tark_premium_lifetime', months: null, subscription: false);

  const BillingPlan({
    required this.sku,
    required this.months,
    required this.subscription,
  });

  final String sku;

  /// `null` for [lifetime] — the entitlement it grants has no expiry.
  final int? months;

  /// Recurring tiers are subscription products; lifetime is a
  /// non-consumable. Neither is ever consumed — consuming would hand the
  /// entitlement back to the store. The flag also picks which native flow
  /// runs (`launchSubscriptionPurchaseFlow` vs the in-app one).
  final bool subscription;

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

class PurchaseSuccess extends PurchaseResult {
  const PurchaseSuccess(this.entitlement);
  final Entitlement entitlement;
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

/// Store-agnostic billing port. Bazaar (Poolakey) and Myket each get their
/// own implementation behind this; nothing above this line knows which store
/// the running build talks to.
///
/// Both stores hand back a purchase payload signed with a per-developer RSA
/// key, verified locally against a public key compiled into the app — which
/// is the whole reason monetization is compatible with an offline product.
/// Implementations must verify that signature *before* returning
/// [PurchaseSuccess]; [EntitlementStore.grant] trusts what it is given.
abstract interface class BillingService {
  /// Whether a store SDK is present and connected in this build.
  Future<bool> isAvailable();

  /// Live prices from the store, in plan order. Empty when billing is
  /// unavailable — the paywall then shows plan names without prices rather
  /// than inventing them.
  Future<List<BillingPlanOffer>> offers();

  Future<PurchaseResult> purchase(BillingPlan plan);

  /// Re-reads purchases already owned by this account — the "restore" path
  /// after a reinstall or device change. Returns `null` when nothing is
  /// owned.
  Future<Entitlement?> restore();
}

/// Stand-in for every build without a store SDK: desktop, web, and Android
/// until the Bazaar/Myket channels land.
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
  Future<Entitlement?> restore() async => null;
}
