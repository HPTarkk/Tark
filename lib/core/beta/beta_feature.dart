import '../l10n/app_localizations.dart';

/// Every capability the product ships *before* it is road-tested.
///
/// The sibling of `PremiumFeature`, and deliberately orthogonal to it: premium
/// answers "what does money buy", beta answers "what might still stumble".
/// A feature can be one, the other, both or neither, and the two never borrow
/// each other's visuals — a beta mark is never a lock, a crown is never a
/// flask.
///
/// Adding a value here is the *only* way a feature becomes beta. Every place
/// that surfaces it asks this enum (through a feature's own mapping, such as
/// `TransferMode.betaFeature`) rather than carrying its own "experimental"
/// flag, so the experimental surface stays enumerable and graduating a
/// feature is deleting one value and following the compile errors.
enum BetaFeature {
  /// Hosting a browser guest over the serverless WebRTC link — the Guest
  /// transport and everything it opens (the invite page, the browser app).
  guestConnection;

  /// Stable persistence id. Never rename a shipped value's key: it names the
  /// "intro already seen" flag on existing installs.
  String get key => switch (this) {
    BetaFeature.guestConnection => 'guest_connection',
  };

  /// The feature's human name, as the beta intro and notices say it.
  String label(AppLocalizations s) => switch (this) {
    BetaFeature.guestConnection => s.beta_feature_guest,
  };
}
