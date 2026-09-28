import 'signed_entitlement.dart';

/// Why the app has to hear from the server before unlocking premium. Each
/// value has its own offline screen, because each means something different
/// to the person holding the phone.
enum CheckReason {
  /// No subscription information on this phone — a fresh install, a new
  /// account, or never subscribed.
  noData,

  /// The last known paid period is over (or was refunded).
  expired,

  /// The account is in the conservative mode and its last successful check
  /// is older than the server's limit.
  staleCheck,
}

/// What the offline-first rules say about premium access right now.
sealed class SubscriptionAccess {
  const SubscriptionAccess();
}

class AccessGranted extends SubscriptionAccess {
  const AccessGranted({this.refreshSuggested = false, this.inGrace = false});

  /// The app should refresh quietly the next time it is online: the paid
  /// period is close to its end, or the account is in the conservative mode.
  /// Never blocks anything.
  final bool refreshSuggested;

  /// The paid period has ended but auto-renew was on, so access continues
  /// for the server's grace period while the renewal is confirmed.
  final bool inGrace;
}

class AccessNeedsCheck extends SubscriptionAccess {
  const AccessNeedsCheck(this.reason);

  final CheckReason reason;
}

/// The whole offline-first rule set, as one pure function of the verified
/// token and a trustworthy "now". No I/O, no clock of its own, so every rule
/// is testable in isolation and the screens can never disagree with the gate.
abstract final class SubscriptionPolicy {
  static SubscriptionAccess evaluate(SignedEntitlement? token, DateTime now) {
    if (token == null || token.status == EntitlementStatus.none) {
      return const AccessNeedsCheck(CheckReason.noData);
    }

    final until = token.until!;
    final policy = token.policy;

    if (token.status != EntitlementStatus.active) {
      return const AccessNeedsCheck(CheckReason.expired);
    }

    // Expiry is checked before the conservative mode: "your subscription
    // ended on <date>" is both true and more useful than "please check in".
    if (!now.isBefore(until)) {
      final graceEnd = until.add(policy.grace);
      final inGrace =
          token.autoRenewing && !token.suspicious && now.isBefore(graceEnd);
      if (!inGrace) return const AccessNeedsCheck(CheckReason.expired);
      return const AccessGranted(refreshSuggested: true, inGrace: true);
    }

    if (token.suspicious) {
      final checkedFor = now.difference(token.issuedAt);
      if (checkedFor >= policy.suspiciousOfflineLimit) {
        return const AccessNeedsCheck(CheckReason.staleCheck);
      }
      return const AccessGranted(refreshSuggested: true);
    }

    final refreshFrom = until.subtract(policy.refreshWindow);
    return AccessGranted(refreshSuggested: !now.isBefore(refreshFrom));
  }
}
