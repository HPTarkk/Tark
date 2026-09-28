import 'dart:convert';

import 'package:cryptography/cryptography.dart';

/// Signs entitlement tokens the way the server will, so tests exercise the
/// real verifier rather than a stub of it.
class TokenFactory {
  TokenFactory._(this._pair, this.publicKey);

  static Future<TokenFactory> create() async {
    final pair = await Ed25519().newKeyPair();
    final public = await pair.extractPublicKey();
    return TokenFactory._(pair, public.bytes);
  }

  final SimpleKeyPair _pair;
  final List<int> publicKey;

  static const kid = 'k1';

  Map<String, List<int>> get keys => {kid: publicKey};

  Future<String> sign(
    Map<String, Object?> payload, {
    String keyId = kid,
  }) async {
    final body = _b64(utf8.encode(jsonEncode(payload)));
    final signed = 'v1.$keyId.$body';
    final signature = await Ed25519().sign(
      ascii.encode(signed),
      keyPair: _pair,
    );
    return '$signed.${_b64(signature.bytes)}';
  }

  static Map<String, Object?> payload({
    String installKey = 'install',
    String status = 'active',
    DateTime? until,
    bool autoRenewing = true,
    bool suspicious = false,
    required DateTime issuedAt,
    int graceH = 72,
    int refreshD = 5,
    int susOfflineH = 72,
  }) => {
    'sub': 'acct_1',
    'ik': installKey,
    'st': status,
    'sku': status == 'none' ? null : 'tark_premium_1m',
    'until': until?.millisecondsSinceEpoch,
    'ar': autoRenewing,
    'sus': suspicious,
    'iat': issuedAt.millisecondsSinceEpoch,
    'pol': {'graceH': graceH, 'refreshD': refreshD, 'susOfflineH': susOfflineH},
  };

  static String _b64(List<int> bytes) =>
      base64Url.encode(bytes).replaceAll('=', '');
}
