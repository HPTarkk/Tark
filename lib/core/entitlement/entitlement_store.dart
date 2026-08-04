import 'entitlement.dart';

/// The one place that knows whether this install has premium access, and the
/// only writer of that fact.
///
/// Shaped like [TransferModeStore]: [initialize] must complete before
/// `runApp` so [current] can be read synchronously from `build` methods and
/// DI factories without every call site awaiting a Future, and [changes]
/// lets screens already on the nav stack react to a purchase completing
/// somewhere else without polling.
///
/// Nothing outside `core/entitlement` should read this directly — ask
/// [LicenseGate] about a specific [PremiumFeature] instead, so platform
/// policy stays in one place.
abstract interface class EntitlementStore {
  /// What the user is entitled to right now, evaluated against the
  /// rollback-guarded clock (see [now]).
  Entitlement get current;

  /// Whether [current] is unlocked at this instant. Convenience for the
  /// overwhelmingly common read; equivalent to `current.isActiveAt(now)`.
  bool get isPremiumActive;

  /// The app's trustworthy "now": the later of the system clock and the
  /// highest instant this install has ever observed. Winding the device date
  /// backwards therefore buys nothing — the water mark does not recede.
  DateTime get now;

  Stream<Entitlement> get changes;

  /// Loads persisted state and, on a genuinely first launch, starts the
  /// trial clock. Must be awaited before the first frame.
  Future<void> initialize();

  /// Records a verified purchase. Callers must have validated the store
  /// receipt *before* calling this — the store persists what it is told.
  Future<void> grant(Entitlement entitlement);

  /// Drops back to the free tier (refund, or a receipt that stops
  /// validating). Does not and cannot restart the trial.
  Future<void> revoke();
}
