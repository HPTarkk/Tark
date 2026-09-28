import 'dart:async';

import 'package:flutter/services.dart';

import '../utils/logger.dart';
import 'billing_service.dart';

/// Cafe Bazaar subscriptions through Poolakey, behind `tark/bazaar_billing`
/// (see BazaarBillingHandler.kt). Android only.
///
/// Everything here is a claim from the phone. A purchase only becomes access
/// after SubscriptionService.submitBazaarPurchase has the server check the
/// token with Bazaar, so this class never decides who is premium and never
/// logs a purchase token.
class BazaarBillingService implements BillingService {
  BazaarBillingService({MethodChannel? channel, String rsaKey = _rsaKey})
    : _channel = channel ?? const MethodChannel('tark/bazaar_billing'),
      _key = rsaKey;

  final MethodChannel _channel;
  final String _key;

  /// The app's RSA public key from the Bazaar developer panel, given at build
  /// time:
  ///
  ///   --dart-define=TARK_BAZAAR_RSA_KEY=KEY_FROM_THE_PANEL
  ///
  /// With it, Poolakey checks Bazaar's signature on every purchase before
  /// Dart sees it: a cheap extra layer in front of the server's check, never
  /// a replacement for it. Without it (dev and CI builds) the check is off
  /// and the server's check is the only one, which Poolakey allows for apps
  /// that verify through Bazaar's REST API. The key is public, not a secret.
  static const _rsaKey = String.fromEnvironment('TARK_BAZAAR_RSA_KEY');

  /// Binding to the Bazaar app is local and normally instant. Past this,
  /// Bazaar is missing, frozen or mid-update, and the paywall should say so
  /// rather than spin.
  static const connectTimeout = Duration(seconds: 10);

  /// Price and inventory reads come from Bazaar's local cache or one quick
  /// round trip; a paywall waiting on them is waiting on nothing useful.
  static const queryTimeout = Duration(seconds: 15);

  Future<bool>? _connecting;
  bool _purchasing = false;

  @override
  Future<bool> isAvailable() => _connect();

  /// Shared by concurrent callers, so a paywall loading prices and a restore
  /// tapped at the same moment bind once.
  Future<bool> _connect() {
    return _connecting ??= () async {
      try {
        final connected = await _channel
            .invokeMethod<bool>('connect', {'rsaKey': _key})
            .timeout(connectTimeout);
        return connected ?? false;
      } on Object catch (error) {
        Logger.diagnostic(
          'Bazaar billing: connect failed (${_describe(error)})',
        );
        return false;
      } finally {
        _connecting = null;
      }
    }();
  }

  @override
  Future<List<BillingPlanOffer>> offers() async {
    if (!await _connect()) return const [];
    try {
      final raw = await _channel
          .invokeListMethod<Object?>('skuDetails', {
            'skus': [for (final plan in BillingPlan.values) plan.sku],
          })
          .timeout(queryTimeout);
      final prices = <BillingPlan, String>{};
      for (final entry in raw ?? const []) {
        if (entry is! Map) continue;
        final plan = BillingPlan.forSku('${entry['sku']}');
        final price = entry['price'];
        if (plan == null || price is! String || price.isEmpty) continue;
        prices[plan] = price;
      }
      // Plan order, not Bazaar's order; a plan Bazaar does not sell is left
      // out rather than shown without a price.
      return [
        for (final plan in BillingPlan.values)
          if (prices[plan] case final price?)
            BillingPlanOffer(plan: plan, price: price),
      ];
    } on Object catch (error) {
      Logger.diagnostic('Bazaar billing: prices failed (${_describe(error)})');
      return const [];
    }
  }

  @override
  Future<PurchaseResult> purchase(BillingPlan plan) async {
    // Bazaar shows one checkout at a time; a double tap must not queue a
    // second one behind it.
    if (_purchasing) return const PurchaseFailed('purchase_in_progress');
    _purchasing = true;
    try {
      if (!await _connect()) return const PurchaseFailed('billing_unavailable');
      final raw = await _channel.invokeMapMethod<String, Object?>('subscribe', {
        'sku': plan.sku,
      });
      final purchase = raw == null ? null : _parse(raw);
      // Bazaar answered for something other than what was bought: hand
      // nothing to the server rather than the wrong plan.
      if (purchase == null || purchase.plan != plan) {
        return const PurchaseFailed('unexpected_purchase');
      }
      return PurchaseSuccess(purchase);
    } on PlatformException catch (error) {
      if (error.code == 'cancelled') return const PurchaseCancelled();
      return PurchaseFailed(error.code);
    } on Object catch (error) {
      return PurchaseFailed(_describe(error));
    } finally {
      _purchasing = false;
    }
  }

  @override
  Future<List<StorePurchase>> restore() async {
    if (!await _connect()) return const [];
    try {
      final raw = await _channel
          .invokeListMethod<Object?>('subscribedProducts')
          .timeout(queryTimeout);
      final seen = <String>{};
      final owned = <(StorePurchase, int)>[];
      for (final entry in raw ?? const []) {
        if (entry is! Map) continue;
        final purchase = _parse(entry);
        if (purchase == null || !seen.add(purchase.purchaseToken)) continue;
        final time = entry['purchaseTime'];
        owned.add((purchase, time is int ? time : 0));
      }
      // Newest first: the caller stops at the first one the server accepts,
      // and the latest renewal is the likeliest to still be running.
      owned.sort((a, b) => b.$2.compareTo(a.$2));
      return [for (final (purchase, _) in owned) purchase];
    } on Object catch (error) {
      Logger.diagnostic('Bazaar billing: restore failed (${_describe(error)})');
      return const [];
    }
  }

  /// A purchase for one of our plans with a usable token, or null. Whether
  /// Bazaar's cache marks it refunded does not matter here: the server asks
  /// Bazaar itself.
  static StorePurchase? _parse(Map<Object?, Object?> raw) {
    final plan = BillingPlan.forSku('${raw['productId']}');
    final token = raw['purchaseToken'];
    if (plan == null || token is! String || token.isEmpty) return null;
    return StorePurchase(plan: plan, purchaseToken: token);
  }

  /// Error kind only. Platform messages can carry purchase details, and those
  /// stay out of the diagnostic log.
  static String _describe(Object error) => switch (error) {
    PlatformException(:final code) => code,
    TimeoutException() => 'timeout',
    MissingPluginException() => 'no_plugin',
    _ => error.runtimeType.toString(),
  };
}
