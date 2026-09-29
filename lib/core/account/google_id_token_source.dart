import 'package:google_sign_in_platform_interface/google_sign_in_platform_interface.dart';

import '../utils/logger.dart';

sealed class GoogleTokenResult {
  const GoogleTokenResult();
}

final class GoogleToken extends GoogleTokenResult {
  const GoogleToken(this.idToken);
  final String idToken;
}

/// The person closed the Google account picker.
final class GoogleCancelled extends GoogleTokenResult {
  const GoogleCancelled();
}

/// Google sign-in could not run on this phone (no Play services, not
/// configured, no Google account and none added, ...).
final class GoogleFailed extends GoogleTokenResult {
  const GoogleFailed(this.reason);

  /// For the diagnostic log.
  final String reason;
}

/// A fresh Google ID token carrying a server-issued nonce.
abstract interface class GoogleIdTokenSource {
  /// False when this build has no Google client configured; the Google
  /// button is then not shown.
  bool get available;

  Future<GoogleTokenResult> idToken({required String nonce});
}

/// [GoogleIdTokenSource] on Android's Credential Manager, through the
/// google_sign_in platform implementation.
///
/// Why the platform interface and not `GoogleSignIn.instance`: the app-facing
/// v7 API takes the nonce only in `initialize()`, which it allows exactly
/// once per process, but the server hands out a new single-use nonce for
/// every sign-in. On Android, `init` only records the parameters on the Dart
/// side and each `authenticate` passes the recorded nonce to Credential
/// Manager's `GetSignInWithGoogleOption.setNonce`, so re-running `init` with
/// the fresh nonce right before each `authenticate` gives a per-request
/// nonce without relying on undefined behaviour of the app-facing class.
class PlatformGoogleIdTokenSource implements GoogleIdTokenSource {
  PlatformGoogleIdTokenSource({required String serverClientId})
    : _serverClientId = serverClientId;

  final String _serverClientId;

  @override
  bool get available => _serverClientId.isNotEmpty;

  @override
  Future<GoogleTokenResult> idToken({required String nonce}) async {
    if (!available) return const GoogleFailed('not_configured');
    final platform = GoogleSignInPlatform.instance;
    try {
      await platform.init(
        InitParameters(serverClientId: _serverClientId, nonce: nonce),
      );
      final result = await platform.authenticate(
        const AuthenticateParameters(),
      );
      // Forget the chosen account on the phone's side, so the next sign-in
      // (or a re-check before deleting the account) shows the picker again
      // instead of silently reusing it.
      try {
        await platform.signOut(const SignOutParams());
      } catch (_) {}
      final token = result.authenticationTokens.idToken;
      if (token == null || token.isEmpty) {
        return const GoogleFailed('no_id_token');
      }
      return GoogleToken(token);
    } on GoogleSignInException catch (error) {
      if (error.code == GoogleSignInExceptionCode.canceled) {
        return const GoogleCancelled();
      }
      Logger.log('Account: Google sign-in failed (${error.code.name})');
      return GoogleFailed(error.code.name);
    } catch (error) {
      Logger.log('Account: Google sign-in failed (${error.runtimeType})');
      return GoogleFailed(error.runtimeType.toString());
    }
  }
}
