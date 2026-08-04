import 'package:get_it/get_it.dart';

import '../utils/logger.dart';
import 'billing_service.dart';
import 'license_gate.dart';
import 'myket_channel.dart';

/// One-shot device diagnostic for the Myket integration, logged under the
/// `TarkBilling` logcat tag alongside the native handler's own output.
///
/// Exists because the two things most likely to be wrong can only be
/// answered on a real device with Myket installed — whether this store build
/// sells subscriptions at all, and whether the SKUs in the developer panel
/// match [BillingPlan]. Both are silent failures otherwise: an unsold SKU
/// just shows up as a paywall with no prices.
///
/// Gated on the same flag as the forced lock, so it never runs in a shipping
/// build:
///
///   --dart-define=TARK_LOCK_PREMIUM=true
abstract final class BillingProbe {
  static const bool _enabled = bool.fromEnvironment('TARK_LOCK_PREMIUM');

  static Future<void> run() async {
    if (!_enabled) return;
    final billing = GetIt.instance<BillingService>();
    final gate = GetIt.instance<LicenseGate>();
    Logger.diagnostic('BillingProbe: canPurchase=${gate.canPurchase}');
    if (!gate.canPurchase) return;

    final available = await billing.isAvailable();
    Logger.diagnostic('BillingProbe: storeAvailable=$available');
    if (!available) {
      Logger.diagnostic(
        'BillingProbe: Myket not installed, or RSA key rejected',
      );
      return;
    }

    // The question the whole plan structure rests on. False here means the
    // recurring tiers must become consumables.
    try {
      final subs = await MyketChannel.subscriptionsSupported();
      Logger.diagnostic('BillingProbe: subscriptionsSupported=$subs');
    } on Object catch (e) {
      Logger.diagnostic('BillingProbe: subscriptionsSupported threw $e');
    }

    final offers = await billing.offers();
    if (offers.isEmpty) {
      Logger.diagnostic(
        'BillingProbe: no offers — SKUs missing from the panel, '
        'not yet published, or ids differ from BillingPlan',
      );
    }
    for (final offer in offers) {
      Logger.diagnostic(
        'BillingProbe: ${offer.plan.sku} '
        '(${offer.plan.subscription ? 'subs' : 'inapp'}) = ${offer.price}',
      );
    }

    final restored = await billing.restore();
    Logger.diagnostic(
      'BillingProbe: restore -> ${restored?.source.key ?? 'nothing'}',
    );
  }
}
