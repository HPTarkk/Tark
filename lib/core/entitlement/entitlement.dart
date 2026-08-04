import 'package:equatable/equatable.dart';

/// Where a user's current access came from. Persisted by name, so these
/// strings are permanent once shipped (same contract as SettingsKeys).
enum EntitlementSource {
  /// No trial, no purchase — free tier.
  none,

  /// The first-run trial. Time-limited, never restored after it lapses.
  trial,

  /// A verified Bazaar (Poolakey) purchase.
  bazaar,

  /// A verified Myket purchase.
  myket;

  static EntitlementSource fromKey(String? key) => switch (key) {
    'trial' => EntitlementSource.trial,
    'bazaar' => EntitlementSource.bazaar,
    'myket' => EntitlementSource.myket,
    _ => EntitlementSource.none,
  };

  String get key => name;
}

/// A snapshot of what the user is entitled to, and until when.
///
/// Deliberately dumb: it holds no clock of its own and never calls
/// [DateTime.now]. Callers pass the time in, because the only trustworthy
/// "now" in this app is [EntitlementStore]'s rollback-guarded one — a value
/// object that read the system clock directly would hand a free subscription
/// to anyone who changes their device date.
class Entitlement extends Equatable {
  const Entitlement({required this.source, this.expiresAt});

  /// Free tier: no trial running, nothing purchased.
  const Entitlement.free() : source = EntitlementSource.none, expiresAt = null;

  final EntitlementSource source;

  /// `null` means "does not expire" — lifetime purchases, and also the free
  /// tier, where there is nothing to expire in the first place. Read it
  /// together with [source], never alone.
  final DateTime? expiresAt;

  bool get isLifetime =>
      source != EntitlementSource.none && expiresAt == null;

  /// Whether premium is unlocked at [now]. The free tier is never active;
  /// everything else is active until its expiry passes.
  bool isActiveAt(DateTime now) {
    if (source == EntitlementSource.none) return false;
    final expiry = expiresAt;
    return expiry == null || now.isBefore(expiry);
  }

  /// Time left before [expiresAt], or `null` for lifetime/free. Clamped at
  /// zero so an expired entitlement reports `Duration.zero` rather than a
  /// negative span the UI would have to special-case.
  Duration? remainingAt(DateTime now) {
    final expiry = expiresAt;
    if (expiry == null) return null;
    final left = expiry.difference(now);
    return left.isNegative ? Duration.zero : left;
  }

  @override
  List<Object?> get props => [source, expiresAt];
}
