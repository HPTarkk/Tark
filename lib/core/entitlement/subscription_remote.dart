/// The server side of the subscription, as the app sees it. Matches
/// `GET /subscription` and `POST /subscription/bazaar/purchases` in
/// backend/api/openapi.yaml.
///
/// Implementations never throw: every way a request can end is one of the
/// [SubscriptionFetch] cases, because each one leads to a different screen.
abstract interface class SubscriptionRemote {
  Future<SubscriptionFetch> fetch({required String installKey});

  Future<SubscriptionFetch> submitBazaarPurchase({
    required String installKey,
    required String sku,
    required String purchaseToken,
  });
}

sealed class SubscriptionFetch {
  const SubscriptionFetch();
}

/// The server answered with a signed entitlement. It is still verified
/// before anything trusts it.
class FetchedEntitlement extends SubscriptionFetch {
  const FetchedEntitlement(
    this.token, {
    required this.bazaarChecked,
    this.planTitle,
  });

  final String token;

  /// The plan's name in the app's language, for display only.
  final String? planTitle;

  /// False when the server could not reach Bazaar and answered with the
  /// last state it verified.
  final bool bazaarChecked;
}

/// No connection, DNS failure, timeout: the phone could not reach us.
class FetchUnreachable extends SubscriptionFetch {
  const FetchUnreachable();
}

/// Reached the server, but it could not answer properly (5xx, malformed
/// reply, rate limited). Shown like "couldn't check" rather than "you're
/// offline", because telling someone with working internet to go find
/// internet is exactly the kind of false accusation the screens avoid.
class FetchServiceTrouble extends SubscriptionFetch {
  const FetchServiceTrouble();
}

/// The request needs a signed-in account and there isn't one (or its
/// session has ended).
class FetchSignedOut extends SubscriptionFetch {
  const FetchSignedOut();
}

/// The purchase token belongs to a different account.
class FetchPurchaseOwnedElsewhere extends SubscriptionFetch {
  const FetchPurchaseOwnedElsewhere();
}

/// Stand-in until the backend and sign-in exist. Reports trouble rather than
/// "offline", so nothing built on top of it ever tells someone their
/// connection is the problem.
class UnavailableSubscriptionRemote implements SubscriptionRemote {
  const UnavailableSubscriptionRemote();

  @override
  Future<SubscriptionFetch> fetch({required String installKey}) async =>
      const FetchServiceTrouble();

  @override
  Future<SubscriptionFetch> submitBazaarPurchase({
    required String installKey,
    required String sku,
    required String purchaseToken,
  }) async => const FetchServiceTrouble();
}
