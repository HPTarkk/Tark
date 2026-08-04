/// Trial length, in one place.
///
/// The business plan runs a 3-month trial for early adopters and drops it to
/// 1 month "once the user base stabilizes" — that transition is meant to be
/// this one-line edit, so resist inlining the duration anywhere else.
///
/// Changing it does not retroactively shorten trials already running: the
/// expiry is computed from each install's own start instant every time it is
/// read, so a shortened policy applies to everyone immediately, including
/// mid-trial users. If you ever need the softer "existing trials keep their
/// original length" behaviour, persist the expiry at trial start instead.
abstract final class TrialPolicy {
  /// Early-adopter phase. Switch to [stabilized] per plan §3.2.
  static const earlyAdopter = Duration(days: 90);

  /// Post-stabilization trial length. Not active yet — swap [length] to this.
  static const stabilized = Duration(days: 30);

  /// The length actually granted to new installs today.
  static const length = earlyAdopter;
}
