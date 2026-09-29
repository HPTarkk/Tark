import 'package:flutter/widgets.dart';

import '../../../../core/account/auth_result.dart';
import '../../../../core/config/support_config.dart';
import '../../../../core/l10n/extension.dart';
import '../../../../core/utils/extensions.dart';

/// The words for an [AuthError]. Always a calm, specific sentence built from
/// the stable `code`; the server's `detail` never reaches a screen. Null
/// for outcomes that need no words (the person closed Google's picker).
///
/// [passwordContext] is set where a wrong password is the only possible
/// meaning of `invalid_credentials` (linking Google, deleting the account,
/// changing the password), so the copy can say "that password" rather than
/// "that email and password".
String? authErrorText(
  BuildContext context,
  AuthError error, {
  bool passwordContext = false,
}) {
  final s = context.getString;
  return switch (error.kind) {
    AuthErrorKind.googleCancelled => null,
    AuthErrorKind.offline => s.auth_error_offline,
    AuthErrorKind.rateLimited => s.auth_error_rate_limited,
    AuthErrorKind.incomplete => s.auth_error_fill,
    AuthErrorKind.emailInvalid => s.auth_error_email,
    AuthErrorKind.invalidRequest => switch (error.field) {
      'email' || 'confirmEmail' => s.auth_error_email,
      'name' => s.auth_error_name,
      _ => s.auth_error_check_input,
    },
    AuthErrorKind.invalidCredentials =>
      passwordContext ? s.auth_error_password_wrong : s.auth_error_credentials,
    AuthErrorKind.accountDisabled => s.auth_error_account_disabled(
      SupportConfig.email,
    ),
    AuthErrorKind.passwordTooShort => s.auth_error_password_short,
    AuthErrorKind.passwordTooLong => s.auth_error_password_long,
    AuthErrorKind.passwordTooCommon => s.auth_error_password_common,
    AuthErrorKind.passwordMatchesEmail => s.auth_error_password_email,
    AuthErrorKind.passwordInvalid => s.auth_error_password_invalid,
    AuthErrorKind.passwordUnchanged => s.auth_error_password_unchanged,
    AuthErrorKind.passwordNotSet => s.auth_error_password_not_set,
    AuthErrorKind.codeInvalid => switch (error.attemptsLeft) {
      final left? when left > 0 => s.auth_error_code(
        left.toString().localized(context),
      ),
      _ => s.auth_error_code_plain,
    },
    AuthErrorKind.codeLocked => s.auth_error_code_locked,
    AuthErrorKind.flowExpired => s.auth_error_flow_expired,
    AuthErrorKind.flowNotFound ||
    AuthErrorKind.flowCompleted => s.auth_error_flow_gone,
    AuthErrorKind.resendLimit => s.auth_error_resend_limit,
    AuthErrorKind.emailAlreadyRegistered => s.auth_error_already_registered,
    AuthErrorKind.googleUnavailable => s.auth_error_google_unavailable,
    AuthErrorKind.googleTokenInvalid ||
    AuthErrorKind.retrySignIn => s.auth_error_google_retry,
    AuthErrorKind.googleEmailUnverified => s.auth_error_google_unverified,
    AuthErrorKind.googleEmailUnsupported => s.auth_error_google_unsupported,
    AuthErrorKind.accountConflict => s.auth_error_account_conflict,
    AuthErrorKind.ticketExpired ||
    AuthErrorKind.ticketLocked => s.auth_error_ticket_expired,
    AuthErrorKind.confirmationMismatch => s.auth_error_confirmation,
    AuthErrorKind.signedOut => s.auth_error_signed_out,
    AuthErrorKind.reauthUnavailable => s.auth_error_reauth(SupportConfig.email),
    // Handled by the screens as steps of their own, not as errors; the
    // fallback words are only for a screen that did not expect them.
    AuthErrorKind.linkRequired ||
    AuthErrorKind.nameRequired ||
    AuthErrorKind.subscriptionActive => s.auth_error_trouble,
    AuthErrorKind.serviceTrouble ||
    AuthErrorKind.unknown => s.auth_error_trouble,
  };
}
