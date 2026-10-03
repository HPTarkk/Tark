import 'package:equatable/equatable.dart';

import '../network/service_api.dart';

/// Every way an account call can end, for screens to pick their words from.
/// The server's `code` strings map onto these; anything unknown becomes
/// [AuthErrorKind.unknown], which screens show with the server's `message`
/// (already in the app's language) or a gentle "something went wrong on our
/// side" — never the server's `detail`.
enum AuthErrorKind {
  /// The phone could not reach the server.
  offline,

  /// The server was reached but could not answer properly.
  serviceTrouble,
  rateLimited,
  invalidRequest,
  invalidCredentials,
  accountDisabled,
  passwordTooShort,
  passwordTooLong,
  passwordTooCommon,
  passwordMatchesEmail,
  passwordInvalid,
  passwordUnchanged,
  passwordNotSet,
  codeInvalid,
  codeLocked,
  flowExpired,
  flowNotFound,
  flowCompleted,
  resendLimit,
  emailAlreadyRegistered,
  linkRequired,
  nameRequired,
  googleTokenInvalid,
  googleEmailUnverified,
  googleEmailUnsupported,
  accountConflict,
  retrySignIn,
  googleUnavailable,
  googleCancelled,
  ticketExpired,
  ticketLocked,
  confirmationMismatch,
  subscriptionActive,
  reauthUnavailable,

  /// No session on this phone, or it ended.
  signedOut,

  /// Checked on the phone before sending: a field left empty.
  incomplete,

  /// Checked on the phone before sending: not shaped like an address.
  emailInvalid,
  unknown,
}

class AuthError extends Equatable {
  const AuthError(
    this.kind, {
    this.code,
    this.attemptsLeft,
    this.retryAfter,
    this.ticket,
    this.maskedEmail,
    this.suggestedName,
    this.autoRenewing,
    this.field,
    this.message,
  });

  final AuthErrorKind kind;

  /// The server's code, for the diagnostic log only.
  final String? code;
  final int? attemptsLeft;
  final Duration? retryAfter;

  /// For [AuthErrorKind.linkRequired] and [AuthErrorKind.nameRequired].
  final String? ticket;

  /// [AuthErrorKind.linkRequired]: the existing account's address, masked.
  final String? maskedEmail;

  /// [AuthErrorKind.nameRequired]: Google's name, when usable.
  final String? suggestedName;

  /// [AuthErrorKind.subscriptionActive]: whether Bazaar will keep renewing.
  final bool? autoRenewing;

  /// The request field the server objected to (`email`, `name`, ...), for
  /// [AuthErrorKind.invalidRequest] and the password codes.
  final String? field;

  /// The server's own sentence for this failure, in the app's language.
  /// Shown only for codes the app has no words of its own for.
  final String? message;

  /// Maps any non-success [ApiResponse] onto an [AuthError].
  factory AuthError.from(ApiResponse response) => switch (response) {
    ApiTransportFailure(:final unreachable) => AuthError(
      unreachable ? AuthErrorKind.offline : AuthErrorKind.serviceTrouble,
    ),
    ApiSignedOut() => const AuthError(AuthErrorKind.signedOut),
    ApiProblem() => AuthError(
      _kindFor(response),
      code: response.code,
      attemptsLeft: response.intField('attemptsLeft'),
      retryAfter: response.retryAfter,
      ticket: response.stringField('ticket'),
      maskedEmail: response.stringField('email'),
      suggestedName: response.stringField('suggestedName'),
      autoRenewing: response.boolField('autoRenewing'),
      field: response.stringField('field'),
      message: response.stringField('message'),
    ),
    ApiOk() => const AuthError(AuthErrorKind.serviceTrouble),
  };

  static AuthErrorKind _kindFor(ApiProblem problem) {
    final byCode = _codes[problem.code];
    if (byCode != null) return byCode;
    if (problem.statusCode == 429) return AuthErrorKind.rateLimited;
    if (problem.statusCode >= 500) return AuthErrorKind.serviceTrouble;
    if (problem.statusCode == 401) return AuthErrorKind.signedOut;
    return AuthErrorKind.unknown;
  }

  static const _codes = <String, AuthErrorKind>{
    'rate_limited': AuthErrorKind.rateLimited,
    'invalid_request': AuthErrorKind.invalidRequest,
    'invalid_credentials': AuthErrorKind.invalidCredentials,
    'account_disabled': AuthErrorKind.accountDisabled,
    'password_too_short': AuthErrorKind.passwordTooShort,
    'password_too_long': AuthErrorKind.passwordTooLong,
    'password_too_common': AuthErrorKind.passwordTooCommon,
    'password_matches_email': AuthErrorKind.passwordMatchesEmail,
    'password_invalid': AuthErrorKind.passwordInvalid,
    'password_unchanged': AuthErrorKind.passwordUnchanged,
    'password_not_set': AuthErrorKind.passwordNotSet,
    'code_invalid': AuthErrorKind.codeInvalid,
    'code_locked': AuthErrorKind.codeLocked,
    'flow_expired': AuthErrorKind.flowExpired,
    'flow_not_found': AuthErrorKind.flowNotFound,
    'flow_completed': AuthErrorKind.flowCompleted,
    'resend_limit': AuthErrorKind.resendLimit,
    'email_already_registered': AuthErrorKind.emailAlreadyRegistered,
    'link_required': AuthErrorKind.linkRequired,
    'name_required': AuthErrorKind.nameRequired,
    'google_token_invalid': AuthErrorKind.googleTokenInvalid,
    'google_email_unverified': AuthErrorKind.googleEmailUnverified,
    'google_email_unsupported': AuthErrorKind.googleEmailUnsupported,
    'account_conflict': AuthErrorKind.accountConflict,
    'retry_sign_in': AuthErrorKind.retrySignIn,
    'google_unavailable': AuthErrorKind.googleUnavailable,
    'ticket_expired': AuthErrorKind.ticketExpired,
    'ticket_locked': AuthErrorKind.ticketLocked,
    'confirmation_mismatch': AuthErrorKind.confirmationMismatch,
    'subscription_active': AuthErrorKind.subscriptionActive,
    'reauth_unavailable': AuthErrorKind.reauthUnavailable,
    'session_ended': AuthErrorKind.signedOut,
    'unauthorized': AuthErrorKind.signedOut,
    'internal_error': AuthErrorKind.serviceTrouble,
    'timeout': AuthErrorKind.serviceTrouble,
  };

  @override
  List<Object?> get props => [
    kind,
    code,
    attemptsLeft,
    retryAfter,
    ticket,
    maskedEmail,
    suggestedName,
    autoRenewing,
    field,
    message,
  ];

  @override
  String toString() =>
      'AuthError(${kind.name}${code == null ? '' : ', $code'})';
}

/// The typed outcome of an account call. Nothing in the account layer
/// throws.
sealed class AuthResult<T> {
  const AuthResult();
}

final class AuthSuccess<T> extends AuthResult<T> {
  const AuthSuccess(this.value);
  final T value;
}

final class AuthFailure<T> extends AuthResult<T> {
  const AuthFailure(this.error);
  final AuthError error;
}
