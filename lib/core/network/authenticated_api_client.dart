import 'dart:async';

import '../utils/logger.dart';
import 'service_api.dart';

/// The token pair a sign-in answers with. Both are opaque strings.
class SessionTokens {
  const SessionTokens({
    required this.accessToken,
    required this.accessTokenExpiresAt,
    required this.refreshToken,
    required this.refreshTokenExpiresAt,
  });

  final String accessToken;
  final DateTime accessTokenExpiresAt;
  final String refreshToken;
  final DateTime refreshTokenExpiresAt;

  /// Reads the `Tokens` shape (also the first half of `Session`). Null when
  /// anything required is missing.
  static SessionTokens? fromJson(Map<String, dynamic> json) {
    final access = json['accessToken'];
    final accessExp = json['accessTokenExpiresAt'];
    final refresh = json['refreshToken'];
    final refreshExp = json['refreshTokenExpiresAt'];
    if (access is! String || access.isEmpty) return null;
    if (refresh is! String || refresh.isEmpty) return null;
    if (accessExp is! num || refreshExp is! num) return null;
    return SessionTokens(
      accessToken: access,
      accessTokenExpiresAt: DateTime.fromMillisecondsSinceEpoch(
        accessExp.toInt(),
        isUtc: true,
      ),
      refreshToken: refresh,
      refreshTokenExpiresAt: DateTime.fromMillisecondsSinceEpoch(
        refreshExp.toInt(),
        isUtc: true,
      ),
    );
  }

  Map<String, Object?> toJson() => {
    'accessToken': accessToken,
    'accessTokenExpiresAt': accessTokenExpiresAt.millisecondsSinceEpoch,
    'refreshToken': refreshToken,
    'refreshTokenExpiresAt': refreshTokenExpiresAt.millisecondsSinceEpoch,
  };
}

/// Where the token pair is kept between launches. Secure storage in the app,
/// a map in tests.
abstract interface class TokenVault {
  Future<SessionTokens?> readTokens();
  Future<void> writeTokens(SessionTokens tokens);
  Future<void> clearTokens();
}

/// Calls that need the signed-in account.
///
/// * Adds `Authorization: Bearer` from the [TokenVault].
/// * Refreshes the pair when the access token has run out, or when the
///   server answers 401 anyway, and then repeats the call once. Refreshes
///   are single-flight: refresh tokens work once, so two calls racing to
///   refresh with the same token would make the server treat the second as
///   theft and end the session.
/// * When the refresh itself is refused, the session is over: the tokens
///   are forgotten, [sessionEnded] fires and the call answers
///   [ApiSignedOut]. A refresh that merely could not reach the server keeps
///   the tokens and answers with that failure.
///
/// Never throws.
class AuthenticatedApiClient {
  AuthenticatedApiClient(
    this._transport,
    this._vault, {
    DateTime Function()? clock,
  }) : _clock = clock ?? DateTime.now;

  final TarkServiceClient _transport;
  final TokenVault _vault;
  final DateTime Function() _clock;
  final _ended = StreamController<void>.broadcast();

  /// A token this close to expiry is refreshed before use rather than sent
  /// to be refused.
  static const _expiryMargin = Duration(seconds: 30);

  Future<_RefreshOutcome>? _refreshing;

  /// Fires when the server ends the session (refresh refused). Not fired
  /// by [forget], which the caller asked for.
  Stream<void> get sessionEnded => _ended.stream;

  Future<bool> hasSession() async => (await _read()) != null;

  /// Stores a pair from a sign-in answer.
  Future<void> adopt(SessionTokens tokens) => _vault.writeTokens(tokens);

  /// Drops the tokens on this phone without telling the server.
  Future<void> forget() async {
    try {
      await _vault.clearTokens();
    } catch (error) {
      Logger.log('Account: could not clear tokens ($error)');
    }
  }

  /// A call that needs no account (sign-in, sign-up, codes).
  Future<ApiResponse> sendAnonymous(ApiRequest request) =>
      _transport.send(request);

  /// A call on behalf of the signed-in account.
  Future<ApiResponse> send(ApiRequest request) async {
    var tokens = await _read();
    if (tokens == null) return const ApiSignedOut();

    final now = _clock();
    if (!now.isBefore(tokens.accessTokenExpiresAt.subtract(_expiryMargin))) {
      final refreshed = await _refresh(tokens);
      switch (refreshed) {
        case _Refreshed(:final tokens):
          return _sendWith(request, tokens, retryOn401: false);
        case _Ended():
          return const ApiSignedOut();
        case _Failed(:final response):
          return response;
      }
    }
    return _sendWith(request, tokens, retryOn401: true);
  }

  /// POST /auth/logout or /auth/logout-all, then forgets the tokens here
  /// whatever the server said: a person who asked to sign out is signed out
  /// on this phone even when the server cannot be reached.
  Future<ApiResponse> logout({bool everywhere = false}) async {
    final response = await send(
      ApiRequest.post(everywhere ? '/auth/logout-all' : '/auth/logout'),
    );
    await forget();
    return response;
  }

  Future<ApiResponse> _sendWith(
    ApiRequest request,
    SessionTokens tokens, {
    required bool retryOn401,
  }) async {
    final response = await _transport.send(_authorize(request, tokens));
    if (!retryOn401 || response is! ApiProblem || response.statusCode != 401) {
      return response;
    }
    final refreshed = await _refresh(tokens);
    return switch (refreshed) {
      _Refreshed(:final tokens) => _transport.send(_authorize(request, tokens)),
      _Ended() => const ApiSignedOut(),
      _Failed(:final response) => response,
    };
  }

  ApiRequest _authorize(ApiRequest request, SessionTokens tokens) => ApiRequest(
    request.method,
    request.path,
    body: request.body,
    idempotencyKey: request.idempotencyKey,
    headers: {
      ...request.headers,
      'Authorization': 'Bearer ${tokens.accessToken}',
    },
  );

  /// One refresh at a time. A caller holding a pair that was already
  /// replaced (another call refreshed first) just takes the new one.
  Future<_RefreshOutcome> _refresh(SessionTokens used) {
    final inFlight = _refreshing;
    if (inFlight != null) return inFlight;
    final future = _refreshFrom(used);
    _refreshing = future;
    return future.whenComplete(() {
      if (identical(_refreshing, future)) _refreshing = null;
    });
  }

  Future<_RefreshOutcome> _refreshFrom(SessionTokens used) async {
    final current = await _read();
    if (current == null) return const _Ended();
    if (current.refreshToken != used.refreshToken) return _Refreshed(current);
    return _doRefresh(current);
  }

  Future<_RefreshOutcome> _doRefresh(SessionTokens current) async {
    final response = await _transport.send(
      ApiRequest.post(
        '/auth/token/refresh',
        body: {'refreshToken': current.refreshToken},
      ),
    );
    switch (response) {
      case ApiOk(:final body):
        final next = SessionTokens.fromJson(body);
        if (next == null) {
          return const _Failed(ApiProblem(502, 'malformed_tokens'));
        }
        try {
          await _vault.writeTokens(next);
        } catch (error) {
          Logger.log('Account: could not store refreshed tokens ($error)');
        }
        return _Refreshed(next);
      case ApiProblem(statusCode: 401, :final code):
        Logger.log('Account: session ended ($code)');
        await forget();
        if (!_ended.isClosed) _ended.add(null);
        return const _Ended();
      case ApiSignedOut():
        return const _Ended();
      case ApiProblem() || ApiTransportFailure():
        return _Failed(response);
    }
  }

  Future<SessionTokens?> _read() async {
    try {
      return await _vault.readTokens();
    } catch (error) {
      Logger.log('Account: stored tokens unreadable ($error)');
      return null;
    }
  }

  void dispose() => _ended.close();
}

sealed class _RefreshOutcome {
  const _RefreshOutcome();
}

final class _Refreshed extends _RefreshOutcome {
  const _Refreshed(this.tokens);
  final SessionTokens tokens;
}

final class _Ended extends _RefreshOutcome {
  const _Ended();
}

final class _Failed extends _RefreshOutcome {
  const _Failed(this.response);
  final ApiResponse response;
}
