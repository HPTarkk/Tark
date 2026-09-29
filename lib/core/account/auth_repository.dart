import '../network/service_api.dart';
import '../utils/logger.dart';
import 'account_models.dart';
import 'account_session.dart';
import 'account_store.dart';
import 'auth_result.dart';
import 'google_id_token_source.dart';

/// Every account flow in backend/api/openapi.yaml the app offers: sign-up
/// with a code or link, sign-in, Google sign-in with linking, password
/// reset and change, and deleting the account.
///
/// Never throws; every method answers an [AuthResult].
class AuthRepository {
  AuthRepository({
    required AccountSession session,
    required AccountStore store,
    required GoogleIdTokenSource google,
    required Future<String> Function() localeCode,
    required Future<String> Function() localName,
  }) : _session = session,
       _store = store,
       _google = google,
       _localeCode = localeCode,
       _localName = localName;

  final AccountSession _session;
  final AccountStore _store;
  final GoogleIdTokenSource _google;
  final Future<String> Function() _localeCode;

  /// The name this phone already uses on the radio: the default for a new
  /// account made with Google, so the person is not asked twice.
  final Future<String> Function() _localName;

  /// Idempotency keys for the email-sending starts, reused while the same
  /// request is retried (a lost answer, a second tap) so it sends one email.
  final _keys = <String, (String, String)>{};

  bool get googleAvailable => _google.available;

  /// The radio name this phone uses, to prefill a new account's name.
  Future<String> localName() async {
    try {
      return (await _localName()).trim();
    } catch (_) {
      return '';
    }
  }

  // ---- Sign-up --------------------------------------------------------------

  Future<AuthResult<PendingFlow>> register({
    required String email,
    required String password,
    required String name,
  }) async {
    final normalized = normalizeEmail(email);
    final body = {
      'email': normalized,
      'password': password,
      'name': name.trim(),
      'locale': await _locale(),
    };
    return _startFlow(
      FlowKind.register,
      normalized,
      '/auth/register',
      body,
      fingerprint: '$normalized\n$password\n${name.trim()}',
    );
  }

  Future<AuthResult<PendingFlow>> forgotPassword(String email) async {
    final normalized = normalizeEmail(email);
    return _startFlow(FlowKind.reset, normalized, '/auth/password/forgot', {
      'email': normalized,
      'locale': await _locale(),
    }, fingerprint: normalized);
  }

  /// The flow this phone started for [kind] and has not finished, if any.
  Future<PendingFlow?> pendingFlow(FlowKind kind) => _store.readFlow(kind);

  Future<void> abandonFlow(FlowKind kind) => _store.clearFlow(kind);

  Future<AuthResult<PendingFlow>> resend(FlowKind kind) async {
    final flow = await _store.readFlow(kind);
    if (flow == null) {
      return const AuthFailure(AuthError(AuthErrorKind.flowNotFound));
    }
    final path = switch (kind) {
      FlowKind.register => '/auth/register/resend',
      FlowKind.reset => '/auth/password/forgot/resend',
    };
    final response = await _session.api.sendAnonymous(
      ApiRequest.post(path, body: {'flowId': flow.flowId}),
    );
    if (response is ApiOk) {
      final next = PendingFlow.fromResponse(kind, flow.email, response.body);
      if (next == null) return _malformed();
      await _store.writeFlow(next);
      return AuthSuccess(next);
    }
    return _failed(response);
  }

  /// Finishes sign-up with the typed [code] or an email link's token, and
  /// signs in.
  Future<AuthResult<AccountProfile>> verifyRegistration({
    String? code,
    String? linkToken,
  }) async {
    final flow = await _store.readFlow(FlowKind.register);
    if (flow == null) {
      return const AuthFailure(AuthError(AuthErrorKind.flowNotFound));
    }
    final response = await _session.api.sendAnonymous(
      ApiRequest.post(
        '/auth/register/verify',
        body: _proof(flow, code: code, linkToken: linkToken),
      ),
    );
    final result = await _adoptSession(response);
    if (result is AuthSuccess || _endsFlow(result)) {
      await _store.clearFlow(FlowKind.register);
    }
    return result;
  }

  // ---- Password reset -------------------------------------------------------

  Future<AuthResult<ResetTicket>> verifyReset({
    String? code,
    String? linkToken,
  }) async {
    final flow = await _store.readFlow(FlowKind.reset);
    if (flow == null) {
      return const AuthFailure(AuthError(AuthErrorKind.flowNotFound));
    }
    final response = await _session.api.sendAnonymous(
      ApiRequest.post(
        '/auth/password/forgot/verify',
        body: _proof(flow, code: code, linkToken: linkToken),
      ),
    );
    if (response is ApiOk) {
      final ticket = response.body['resetTicket'];
      final expires = response.body['expiresAt'];
      if (ticket is! String || expires is! num) return _malformed();
      return AuthSuccess(
        ResetTicket(
          ticket,
          DateTime.fromMillisecondsSinceEpoch(expires.toInt(), isUtc: true),
        ),
      );
    }
    final failure = _failed<ResetTicket>(response);
    if (_endsFlow(failure)) await _store.clearFlow(FlowKind.reset);
    return failure;
  }

  /// Sets the new password and signs in. Every other session ends.
  Future<AuthResult<AccountProfile>> resetPassword({
    required ResetTicket ticket,
    required String newPassword,
  }) async {
    final response = await _session.api.sendAnonymous(
      ApiRequest.post(
        '/auth/password/reset',
        body: {'resetTicket': ticket.value, 'newPassword': newPassword},
      ),
    );
    final result = await _adoptSession(response);
    if (result is AuthSuccess) await _store.clearFlow(FlowKind.reset);
    return result;
  }

  Future<AuthResult<void>> changePassword({
    required String currentPassword,
    required String newPassword,
  }) async {
    final response = await _session.api.send(
      ApiRequest.post(
        '/auth/password/change',
        body: {'currentPassword': currentPassword, 'newPassword': newPassword},
      ),
    );
    if (response is ApiOk) return const AuthSuccess(null);
    return _failed(response);
  }

  // ---- Sign-in --------------------------------------------------------------

  Future<AuthResult<AccountProfile>> login({
    required String email,
    required String password,
  }) async {
    final response = await _session.api.sendAnonymous(
      ApiRequest.post(
        '/auth/login',
        body: {'email': normalizeEmail(email), 'password': password},
      ),
    );
    return _adoptSession(response);
  }

  /// Google sign-in: a server nonce, then the Google account picker, then
  /// the server. A [AuthErrorKind.linkRequired] failure carries the ticket
  /// for [linkGoogle]; [AuthErrorKind.nameRequired] the one for
  /// [completeGoogle]. A new account takes [name], or else the local one.
  Future<AuthResult<AccountProfile>> signInWithGoogle({String? name}) async {
    final token = await _googleIdToken();
    if (token case AuthFailure(:final error)) return AuthFailure(error);
    final idToken = (token as AuthSuccess<String>).value;
    String? trimmed = name?.trim();
    if (trimmed == null || trimmed.isEmpty) {
      try {
        trimmed = (await _localName()).trim();
      } catch (_) {
        trimmed = null;
      }
    }
    final response = await _session.api.sendAnonymous(
      ApiRequest.post(
        '/auth/google',
        body: {
          'idToken': idToken,
          if (trimmed != null && trimmed.isNotEmpty) 'name': trimmed,
          'locale': await _locale(),
        },
      ),
    );
    return _adoptSession(response);
  }

  /// Adds Google to an existing password account, after its password.
  Future<AuthResult<AccountProfile>> linkGoogle({
    required String ticket,
    required String password,
  }) async {
    final response = await _session.api.sendAnonymous(
      ApiRequest.post(
        '/auth/google/link',
        body: {
          'ticket': ticket,
          'password': password,
          'locale': await _locale(),
        },
      ),
    );
    return _adoptSession(response);
  }

  /// Finishes a Google sign-up that needed a name.
  Future<AuthResult<AccountProfile>> completeGoogle({
    required String ticket,
    required String name,
  }) async {
    final response = await _session.api.sendAnonymous(
      ApiRequest.post(
        '/auth/google/complete',
        body: {'ticket': ticket, 'name': name.trim()},
      ),
    );
    return _adoptSession(response);
  }

  // ---- Account --------------------------------------------------------------

  Future<void> signOut({bool everywhere = false}) =>
      _session.signOut(everywhere: everywhere);

  /// Deletes the account for good. Needs the typed email, and fresh proof:
  /// [password], or with [withGoogle] a new Google ID token. While a paid
  /// period runs the server also wants [subscriptionAcknowledged], and
  /// answers [AuthErrorKind.subscriptionActive] without it.
  Future<AuthResult<void>> deleteAccount({
    required String confirmEmail,
    String? password,
    bool withGoogle = false,
    bool subscriptionAcknowledged = false,
  }) async {
    String? idToken;
    if (withGoogle) {
      final token = await _googleIdToken();
      if (token case AuthFailure(:final error)) return AuthFailure(error);
      idToken = (token as AuthSuccess<String>).value;
    }
    final response = await _session.api.send(
      ApiRequest.post(
        '/account/delete',
        body: {
          'confirmEmail': confirmEmail.trim(),
          'currentPassword': ?password,
          'googleIdToken': ?idToken,
          'subscriptionAcknowledged': subscriptionAcknowledged,
          'locale': await _locale(),
        },
      ),
    );
    if (response is ApiOk) {
      Logger.log('Account: deleted');
      await _session.endAfterServer();
      return const AuthSuccess(null);
    }
    return _failed(response);
  }

  // ---- Plumbing -------------------------------------------------------------

  Future<AuthResult<PendingFlow>> _startFlow(
    FlowKind kind,
    String email,
    String path,
    Map<String, Object?> body, {
    required String fingerprint,
  }) async {
    final previous = _keys[path];
    final key = previous != null && previous.$1 == fingerprint
        ? previous.$2
        : newIdempotencyKey();
    _keys[path] = (fingerprint, key);
    final response = await _session.api.sendAnonymous(
      ApiRequest.post(path, body: body, idempotencyKey: key),
    );
    if (response is ApiOk) {
      _keys.remove(path);
      final flow = PendingFlow.fromResponse(kind, email, response.body);
      if (flow == null) return _malformed();
      await _store.writeFlow(flow);
      return AuthSuccess(flow);
    }
    return _failed(response);
  }

  /// A nonce from the server, then an ID token from Google carrying it.
  Future<AuthResult<String>> _googleIdToken() async {
    if (!_google.available) {
      return const AuthFailure(AuthError(AuthErrorKind.googleUnavailable));
    }
    final nonceResponse = await _session.api.sendAnonymous(
      const ApiRequest.post('/auth/google/nonce'),
    );
    if (nonceResponse is! ApiOk) return _failed(nonceResponse);
    final nonce = nonceResponse.body['nonce'];
    if (nonce is! String || nonce.isEmpty) return _malformed();
    return switch (await _google.idToken(nonce: nonce)) {
      GoogleToken(:final idToken) => AuthSuccess(idToken),
      GoogleCancelled() => const AuthFailure(
        AuthError(AuthErrorKind.googleCancelled),
      ),
      GoogleFailed() => const AuthFailure(
        AuthError(AuthErrorKind.googleUnavailable),
      ),
    };
  }

  Future<AuthResult<AccountProfile>> _adoptSession(ApiResponse response) async {
    if (response is! ApiOk) return _failed(response);
    final profile = await _session.adopt(response.body);
    if (profile == null) return _malformed();
    return AuthSuccess(profile);
  }

  Map<String, Object?> _proof(
    PendingFlow flow, {
    String? code,
    String? linkToken,
  }) => {
    'flowId': flow.flowId,
    if (linkToken != null) 'linkToken': linkToken else 'code': code,
  };

  /// Failures after which the stored flow can never verify again.
  static bool _endsFlow(AuthResult<Object?> result) => switch (result) {
    AuthFailure(:final error) => const {
      AuthErrorKind.flowExpired,
      AuthErrorKind.flowNotFound,
      AuthErrorKind.flowCompleted,
      AuthErrorKind.emailAlreadyRegistered,
    }.contains(error.kind),
    AuthSuccess() => false,
  };

  Future<String> _locale() async {
    try {
      final code = await _localeCode();
      return code == 'en' ? 'en' : 'fa';
    } catch (_) {
      return 'fa';
    }
  }

  static AuthFailure<T> _failed<T>(ApiResponse response) {
    final error = AuthError.from(response);
    Logger.log('Account: call failed ($error)');
    return AuthFailure(error);
  }

  static AuthFailure<T> _malformed<T>() =>
      const AuthFailure(AuthError(AuthErrorKind.serviceTrouble));
}

/// Trimmed and lower-cased; the server compares addresses that way too.
String normalizeEmail(String raw) => raw.trim().toLowerCase();

/// Whether [raw] looks enough like an address to send. The server has the
/// final word; this only catches typos before a round trip.
bool looksLikeEmail(String raw) {
  final value = raw.trim();
  if (value.length > 254 || value.contains(' ')) return false;
  return RegExp(r'^[^@\s]+@[^@\s]+\.[^@\s]+$').hasMatch(value);
}

/// Persian and Arabic-Indic digits typed on a Persian keyboard, as ASCII.
/// The server takes `^[0-9]{6}$`.
String asciiDigits(String raw) {
  final out = StringBuffer();
  for (final rune in raw.runes) {
    if (rune >= 0x06F0 && rune <= 0x06F9) {
      out.writeCharCode(0x30 + rune - 0x06F0);
    } else if (rune >= 0x0660 && rune <= 0x0669) {
      out.writeCharCode(0x30 + rune - 0x0660);
    } else if (rune >= 0x30 && rune <= 0x39) {
      out.writeCharCode(rune);
    }
  }
  return out.toString();
}
