import '../utils/logger.dart';
import 'billing_service.dart';
import 'entitlement.dart';
import 'myket_channel.dart';

/// Myket-backed [BillingService].
///
/// The RSA public key is compiled in from `--dart-define-from-file=billing.json`
/// (gitignored). It is a *public* key — it ships inside the APK by design —
/// so the file exists to keep per-store keys separable, not to keep a secret.
/// An empty key simply leaves billing unavailable, which is the same branch
/// desktop already takes.
class MyketBillingService implements BillingService {
  MyketBillingService();

  static const _rsaKey = String.fromEnvironment('MYKET_RSA_KEY');

  /// One setup attempt per process. `null` until the first call resolves.
  Future<bool>? _setup;

  Future<bool> _ensureReady() {
    return _setup ??= () async {
      if (_rsaKey.isEmpty) {
        Logger.diagnostic(
          'Myket billing: no MYKET_RSA_KEY compiled in, disabled',
        );
        return false;
      }
      try {
        final ok = await MyketChannel.init(_rsaKey);
        Logger.diagnostic('Myket billing: setup ${ok ? 'ok' : 'failed'}');
        return ok;
      } on Object catch (e) {
        // Myket not installed is the ordinary case here, not an error worth
        // surfacing — the paywall just reports no purchase path.
        Logger.diagnostic('Myket billing: setup threw $e');
        return false;
      }
    }();
  }

  @override
  Future<bool> isAvailable() => _ensureReady();

  @override
  Future<List<BillingPlanOffer>> offers() async {
    final inventory = await _inventory();
    if (inventory == null) return const [];
    final skus = inventory['skus'];
    if (skus is! List) return const [];

    final offers = <BillingPlanOffer>[];
    for (final entry in skus) {
      if (entry is! Map) continue;
      final plan = BillingPlan.forSku('${entry['sku']}');
      final price = entry['price'];
      if (plan == null || price == null) continue;
      offers.add(BillingPlanOffer(plan: plan, price: '$price'));
    }
    // Keep the paywall's row order stable and independent of what the store
    // happened to return.
    offers.sort((a, b) => a.plan.index.compareTo(b.plan.index));
    return offers;
  }

  @override
  Future<PurchaseResult> purchase(BillingPlan plan) async {
    if (!await _ensureReady()) {
      return const PurchaseFailed('billing_unavailable');
    }
    try {
      final response = await MyketChannel.purchase(
        sku: plan.sku,
        subscription: plan.subscription,
      );
      if (response == null) return const PurchaseFailed('no_response');
      if (response['ok'] != true) {
        final code = response['response'];
        final message = '${response['message'] ?? 'purchase_failed'}';
        // A dismissed dialog arrives as a failure. Treat it as the cancel it
        // is so the paywall stays silent instead of showing an error the user
        // caused on purpose. Two codes reach us depending on where the flow
        // was abandoned — the SDK's own, and the store's.
        if (code == _iabHelperUserCancelled ||
            code == _billingResponseUserCanceled) {
          return const PurchaseCancelled();
        }
        if (code == _iabHelperSubscriptionsNotAvailable) {
          // The one failure that means the plan structure itself is wrong,
          // not this attempt: this Myket build cannot sell subscriptions at
          // all, so the recurring tiers need to become consumables.
          Logger.diagnostic(
            'Myket billing: SUBSCRIPTIONS NOT AVAILABLE on this store',
          );
          return const PurchaseFailed('subscriptions_unavailable');
        }
        Logger.diagnostic('Myket billing: purchase failed ($code) — $message');
        return PurchaseFailed(message);
      }
      final purchase = response['purchase'];
      if (purchase is! Map) return const PurchaseFailed('no_purchase');
      // Reaching here means IabHelper already verified the signature against
      // the RSA key; an unverified purchase never comes back as ok.
      return PurchaseSuccess(_entitlementFor(plan, purchase));
    } on Object catch (e) {
      Logger.diagnostic('Myket billing: purchase threw $e');
      return PurchaseFailed('$e');
    }
  }

  @override
  Future<Entitlement?> restore() async {
    final inventory = await _inventory();
    if (inventory == null) return null;
    final purchases = inventory['purchases'];
    if (purchases is! List) return null;

    Entitlement? best;
    for (final entry in purchases) {
      if (entry is! Map) continue;
      final plan = BillingPlan.forSku('${entry['sku']}');
      if (plan == null) continue;
      final candidate = _entitlementFor(plan, entry);
      best = _preferred(best, candidate);
    }
    return best;
  }

  Future<Map<Object?, Object?>?> _inventory() async {
    if (!await _ensureReady()) return null;
    try {
      final response = await MyketChannel.queryInventory(
        inappSkus: [
          for (final p in BillingPlan.values)
            if (!p.subscription) p.sku,
        ],
        subsSkus: [
          for (final p in BillingPlan.values)
            if (p.subscription) p.sku,
        ],
      );
      if (response == null || response['ok'] != true) {
        Logger.diagnostic('Myket billing: inventory ${response?['message']}');
        return null;
      }
      return response;
    } on Object catch (e) {
      Logger.diagnostic('Myket billing: inventory threw $e');
      return null;
    }
  }

  /// Lifetime has no expiry. A subscription's expiry is computed from its
  /// purchase time because Myket's purchase payload carries no end date —
  /// which is why [restore] runs again on later launches: a renewal moves
  /// `purchaseTime` forward and the expiry recomputes with it.
  Entitlement _entitlementFor(
    BillingPlan plan,
    Map<Object?, Object?> purchase,
  ) {
    final months = plan.months;
    if (months == null) {
      return const Entitlement(source: EntitlementSource.myket);
    }
    final rawTime = purchase['purchaseTime'];
    final purchasedAt = rawTime is int
        ? DateTime.fromMillisecondsSinceEpoch(rawTime)
        : DateTime.now();
    return Entitlement(
      source: EntitlementSource.myket,
      // Calendar-month arithmetic: DateTime normalises an overflowing month
      // (13 -> January of the next year) on its own.
      expiresAt: DateTime(
        purchasedAt.year,
        purchasedAt.month + months,
        purchasedAt.day,
        purchasedAt.hour,
        purchasedAt.minute,
      ),
    );
  }

  /// Lifetime beats everything; otherwise the later expiry wins, so someone
  /// holding both a subscription and a leftover term keeps the longer one.
  Entitlement? _preferred(Entitlement? a, Entitlement? b) {
    if (a == null) return b;
    if (b == null) return a;
    if (a.isLifetime) return a;
    if (b.isLifetime) return b;
    final aEnd = a.expiresAt;
    final bEnd = b.expiresAt;
    if (aEnd == null) return a;
    if (bEnd == null) return b;
    return aEnd.isAfter(bEnd) ? a : b;
  }

  // Result codes read off ir.myket.billingclient.IabHelper (v1.19).
  static const _iabHelperUserCancelled = -1005;
  static const _iabHelperSubscriptionsNotAvailable = -1009;
  static const _billingResponseUserCanceled = 1;
}
