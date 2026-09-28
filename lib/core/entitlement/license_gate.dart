import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter/foundation.dart' show kIsWeb;

import 'premium_feature.dart';
import 'subscription_service.dart';

/// Whether this build sells anything at all. One place, read by the gate and
/// by DI (which skips the subscription machinery entirely when it is off).
abstract final class Monetization {
  /// Monetization is **parked**: Tark ships unlocked until the release that
  /// starts charging, which flips this at build time:
  ///
  ///   flutter build appbundle --release --dart-define=TARK_MONETIZED=true
  static const bool _enabled = bool.fromEnvironment('TARK_MONETIZED');

  /// Build-time override that forces every gate shut, so the subscription
  /// screens can be exercised on a device without a backend:
  ///
  ///   flutter build apk --release --dart-define=TARK_LOCK_PREMIUM=true
  ///
  /// Defaults to false, so a normal build can never ship locked by accident.
  static const bool forceLocked = bool.fromEnvironment('TARK_LOCK_PREMIUM');

  /// Bazaar is Android-only, so Android is the only platform with a purchase
  /// path. Gating anywhere else would be a locked door with no key — desktop,
  /// iOS and web builds run fully unlocked by decision, not by oversight.
  static final bool active =
      (_enabled || forceLocked) && !kIsWeb && Platform.isAndroid;
}

/// The single question the rest of the app is allowed to ask about money:
/// "may this install use [PremiumFeature] X right now?"
///
/// Everything funnels through here so the paid boundary stays auditable —
/// grep for `allows(` and you have every gate in the product. Cubits must
/// not read [SubscriptionService] and must not carry their own `isPremium`
/// flags; that is exactly the scattering this class exists to prevent.
abstract interface class LicenseGate {
  bool allows(PremiumFeature feature);

  /// True where a purchase is actually possible. Screens use it to decide
  /// whether to show upgrade affordances at all — offering a paywall with no
  /// checkout behind it is worse than showing nothing.
  bool get canPurchase;

  /// Fires whenever access may have changed, so a screen holding a gated
  /// control can re-evaluate without polling.
  Stream<void> get changes;
}

class LicenseGateImpl implements LicenseGate {
  LicenseGateImpl(this._subscription, {bool? monetized, bool? forceLocked})
    : _monetized = monetized ?? Monetization.active,
      _forceLocked = forceLocked ?? Monetization.forceLocked;

  final SubscriptionService _subscription;
  final bool _monetized;
  final bool _forceLocked;

  @override
  bool get canPurchase => _monetized;

  @override
  bool allows(PremiumFeature feature) {
    if (!_monetized) return true;
    if (_forceLocked) return false;
    return _subscription.isPremiumActive;
  }

  @override
  Stream<void> get changes => _subscription.changes;
}
