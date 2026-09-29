import 'dart:async';
import 'dart:math' as math;

import '../network/authenticated_api_client.dart';
import '../network/service_api.dart';
import '../utils/logger.dart';
import 'subscription_remote.dart';

/// [SubscriptionRemote] against the backend: GET /subscription and
/// POST /subscription/bazaar/purchases, on behalf of the signed-in account.
class HttpSubscriptionRemote implements SubscriptionRemote {
  HttpSubscriptionRemote(
    this._api, {
    Future<void> Function(Duration)? sleep,
    String Function()? newKey,
    this.maxAttempts = 4,
  }) : _sleep = sleep ?? Future<void>.delayed,
       _newKey = newKey ?? newIdempotencyKey;

  final AuthenticatedApiClient _api;
  final Future<void> Function(Duration) _sleep;
  final String Function() _newKey;

  /// Tries of a purchase submission in all, the first included. Bazaar
  /// usually shows a fresh purchase within seconds; past this the person
  /// gets "couldn't check" and "restore" submits it again later.
  final int maxAttempts;

  /// Bounds on a retry wait, whatever the server suggests: never hammer,
  /// never leave the paywall spinning for half a minute per try.
  static const _minWait = Duration(seconds: 2);
  static const _maxWait = Duration(seconds: 10);

  /// Answers the server tells us to repeat with the same Idempotency-Key.
  static const _retryable = {
    'purchase_not_found_yet',
    'bazaar_unavailable',
    'request_in_progress',
  };

  @override
  Future<SubscriptionFetch> fetch({required String installKey}) async {
    final response = await _api.send(
      ApiRequest.get(
        '/subscription',
        headers: {'X-Tark-Install-Key': installKey},
      ),
    );
    return _map(response);
  }

  @override
  Future<SubscriptionFetch> submitBazaarPurchase({
    required String installKey,
    required String sku,
    required String purchaseToken,
  }) async {
    // One key for every try of this one purchase: the server then verifies
    // and binds it once, however many of our requests reach it.
    final key = _newKey();
    final request = ApiRequest.post(
      '/subscription/bazaar/purchases',
      headers: {'X-Tark-Install-Key': installKey},
      body: {'sku': sku, 'purchaseToken': purchaseToken},
      idempotencyKey: key,
    );
    for (var attempt = 1; ; attempt++) {
      final response = await _api.send(request);
      final retry =
          response is ApiProblem && _retryable.contains(response.code);
      if (!retry || attempt >= maxAttempts) return _map(response);
      final wait = _waitFor(response, attempt);
      Logger.log(
        'Subscription: purchase not confirmed yet (${response.code}), '
        'retrying in ${wait.inSeconds}s',
      );
      await _sleep(wait);
    }
  }

  /// The server's hint, clamped; doubling from [_minWait] without one.
  Duration _waitFor(ApiProblem problem, int attempt) {
    final hinted = problem.retryAfter;
    final fallback = _minWait * math.pow(2, attempt - 1).toInt();
    final wait = hinted ?? fallback;
    if (wait < _minWait) return _minWait;
    if (wait > _maxWait) return _maxWait;
    return wait;
  }

  static SubscriptionFetch _map(ApiResponse response) => switch (response) {
    ApiOk(:final body) => switch ((
      body['entitlement'],
      body['bazaarChecked'],
    )) {
      (final String token, final bool checked) when token.isNotEmpty =>
        FetchedEntitlement(token, bazaarChecked: checked),
      (final String token, _) when token.isNotEmpty => FetchedEntitlement(
        token,
        bazaarChecked: true,
      ),
      _ => const FetchServiceTrouble(),
    },
    ApiSignedOut() => const FetchSignedOut(),
    ApiProblem(statusCode: 401) => const FetchSignedOut(),
    ApiProblem(code: 'purchase_owned_elsewhere') =>
      const FetchPurchaseOwnedElsewhere(),
    ApiProblem() => const FetchServiceTrouble(),
    ApiTransportFailure(:final unreachable) =>
      unreachable ? const FetchUnreachable() : const FetchServiceTrouble(),
  };
}
