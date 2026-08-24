import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:injectable/injectable.dart';

import 'entitlement.dart';
import 'entitlement_store.dart';
import 'premium_feature.dart';

/// The single question the rest of the app is allowed to ask about money:
/// "may this install use [PremiumFeature] X right now?"
///
/// Everything funnels through here so the paid boundary stays auditable —
/// grep for `allows(` and you have every gate in the product. Cubits must
/// not read [EntitlementStore] and must not carry their own `isPremium`
/// flags; that is exactly the scattering this class exists to prevent.
abstract interface class LicenseGate {
  bool allows(PremiumFeature feature);

  /// True where a purchase is actually possible. Screens use it to decide
  /// whether to show upgrade affordances at all — offering a paywall with no
  /// checkout behind it is worse than showing nothing.
  bool get canPurchase;

  /// Fires whenever entitlement changes, so a screen holding a gated control
  /// can re-evaluate without polling.
  Stream<Entitlement> get changes;
}

@LazySingleton(as: LicenseGate)
class LicenseGateImpl implements LicenseGate {
  LicenseGateImpl(this._store);

  final EntitlementStore _store;

  /// Monetization is **parked**. Tark ships unlocked everywhere and asks for
  /// donations instead of selling tiers, so this defaults off and every
  /// `allows(...)` below answers yes.
  ///
  /// Nothing is deleted: the store and the paywall stay wired and compiled.
  /// Flipping this back on is the whole of un-parking it — once a store
  /// channel (Bazaar) exists behind [BillingService]:
  ///
  ///   flutter build apk --release --dart-define=TARK_MONETIZED=true
  static const bool _monetizationEnabled = bool.fromEnvironment(
    'TARK_MONETIZED',
  );

  /// Bazaar is Android-only, so Android is the only platform with a purchase
  /// path. Gating anywhere else would be a locked door with no key — desktop
  /// and web builds run fully unlocked by decision, not by oversight. Revisit
  /// only if a store ever ships for those platforms.
  ///
  /// [_forceLocked] implies monetization, so the paywall stays exercisable on
  /// a device with that one flag while the feature is parked.
  static final bool _monetized =
      (_monetizationEnabled || _forceLocked) && !kIsWeb && Platform.isAndroid;

  /// Build-time override that forces every gate shut, so the paywall can be
  /// exercised on a device without waiting out a 90-day trial. No store
  /// channel is wired up yet, so this only exercises the gate and paywall
  /// UI, not a real purchase:
  ///
  ///   flutter build apk --release --dart-define=TARK_LOCK_PREMIUM=true
  ///
  /// Defaults to false, so a normal build can never ship locked by accident.
  static const bool _forceLocked = bool.fromEnvironment('TARK_LOCK_PREMIUM');

  @override
  bool get canPurchase => _monetized;

  @override
  bool allows(PremiumFeature feature) {
    if (!_monetized) return true;
    if (_forceLocked) return false;
    return _store.isPremiumActive;
  }

  @override
  Stream<Entitlement> get changes => _store.changes;
}
