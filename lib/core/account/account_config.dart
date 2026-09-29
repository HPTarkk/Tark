import 'dart:io' show Platform;

import 'package:flutter/foundation.dart' show kIsWeb;

import '../entitlement/license_gate.dart';

/// Build-time switches for accounts and sign-in.
abstract final class AccountConfig {
  /// Accounts exist for one reason: a subscription belongs to an account.
  /// So sign-in shows wherever the paid features are live (see
  /// [Monetization]); a build that sells nothing does not ask anyone to
  /// sign in. For testing sign-in on a build that is not monetized yet:
  ///
  ///   flutter run --dart-define=TARK_ACCOUNTS=true
  static const bool _forced = bool.fromEnvironment('TARK_ACCOUNTS');

  /// Sign-in is Android only for now (the backend also accepts iOS); never
  /// on the web guest build.
  static final bool enabled =
      !kIsWeb && Platform.isAndroid && (Monetization.active || _forced);

  /// The OAuth "web" client id the backend verifies Google ID tokens
  /// against (their audience). Unknown until the Google Cloud project is set
  /// up; while empty, the Google button is not shown at all.
  ///
  ///   --dart-define=TARK_GOOGLE_SERVER_CLIENT_ID=123-abc.apps.googleusercontent.com
  static const googleServerClientId = String.fromEnvironment(
    'TARK_GOOGLE_SERVER_CLIENT_ID',
  );

  /// The `X-Tark-Platform` header value; the server accepts android and ios.
  static String? get platformHeader {
    if (kIsWeb) return null;
    if (Platform.isAndroid) return 'android';
    if (Platform.isIOS) return 'ios';
    return null;
  }

  /// Where email links point. `https://tarkk.ir/v/<register|reset|email>`.
  static const linkHost = 'tarkk.ir';
  static const linkPathPrefix = '/v/';
}
