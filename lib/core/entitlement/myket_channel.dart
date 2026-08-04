import 'package:flutter/services.dart';

/// Thin Dart mirror of `BillingHandler.kt` on the `tark/billing` channel.
///
/// Deliberately dumb: it moves maps across the channel and does no policy.
/// Everything that decides what a purchase *means* lives in
/// [MyketBillingService].
abstract final class MyketChannel {
  static const _channel = MethodChannel('tark/billing');

  /// Binds to the Myket service with the store's RSA public key. False when
  /// Myket isn't installed, the key is empty, or setup otherwise fails —
  /// every later call then returns its own "unavailable" shape rather than
  /// throwing.
  static Future<bool> init(String rsaKey) async {
    final ok = await _channel.invokeMethod<bool>('init', {'rsaKey': rsaKey});
    return ok ?? false;
  }

  /// Whether this Myket build supports subscription products at all. The
  /// SDK exposes it; the published Flutter plugin never did.
  static Future<bool> subscriptionsSupported() async {
    final ok = await _channel.invokeMethod<bool>('subscriptionsSupported');
    return ok ?? false;
  }

  /// Owned purchases plus SKU details for both families in one round trip.
  /// Subscription SKUs must be passed separately — the underlying query is
  /// per item type.
  static Future<Map<Object?, Object?>?> queryInventory({
    required List<String> inappSkus,
    required List<String> subsSkus,
  }) {
    return _channel.invokeMethod<Map<Object?, Object?>>('queryInventory', {
      'inappSkus': inappSkus,
      'subsSkus': subsSkus,
    });
  }

  /// Opens Myket's purchase UI. [subscription] picks
  /// `launchSubscriptionPurchaseFlow` over the in-app flow.
  static Future<Map<Object?, Object?>?> purchase({
    required String sku,
    required bool subscription,
    String? payload,
  }) {
    return _channel.invokeMethod<Map<Object?, Object?>>('purchase', {
      'sku': sku,
      'subscription': subscription,
      'payload': payload,
    });
  }

  /// Consumables only. Never call this for a subscription or for the
  /// lifetime product — it hands the entitlement back to the store.
  static Future<bool> consume({
    required String itemType,
    required String originalJson,
    required String signature,
  }) async {
    final ok = await _channel.invokeMethod<bool>('consume', {
      'itemType': itemType,
      'originalJson': originalJson,
      'signature': signature,
    });
    return ok ?? false;
  }
}
