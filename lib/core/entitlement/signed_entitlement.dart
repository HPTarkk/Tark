import 'dart:convert';

import 'package:cryptography/cryptography.dart';
import 'package:equatable/equatable.dart';

/// What the server last said about the account's subscription. Mirrors
/// `EntitlementPayload.st` in backend/api/openapi.yaml.
enum EntitlementStatus {
  /// Never subscribed.
  none,

  /// A paid period is running. Auto-renew may be on or off — turning it off
  /// is an ordinary choice and never makes an account suspicious.
  active,

  /// The paid period ended normally.
  expired,

  /// Refunded or revoked before the paid period ended.
  refunded;

  static EntitlementStatus? fromWire(Object? value) => switch (value) {
    'none' => EntitlementStatus.none,
    'active' => EntitlementStatus.active,
    'expired' => EntitlementStatus.expired,
    'refunded' => EntitlementStatus.refunded,
    _ => null,
  };
}

/// Offline policy numbers. They travel inside the signed token rather than
/// living in the binary, so tuning them never needs an app release.
class EntitlementPolicy extends Equatable {
  const EntitlementPolicy({
    required this.grace,
    required this.refreshWindow,
    required this.suspiciousOfflineLimit,
  });

  /// How long an auto-renewing subscription stays usable offline after its
  /// period ends — the renewal almost certainly happened, the phone just
  /// hasn't heard about it yet.
  final Duration grace;

  /// How long before the period ends the app starts refreshing quietly
  /// whenever it happens to be online.
  final Duration refreshWindow;

  /// For an account in the conservative mode: how long after the last
  /// successful check the app still works offline.
  final Duration suspiciousOfflineLimit;

  @override
  List<Object?> get props => [grace, refreshWindow, suspiciousOfflineLimit];
}

/// A server-issued, Ed25519-signed statement of the account's subscription.
///
/// This is the only form subscription state is ever stored in. Nothing here
/// is trusted until [EntitlementVerifier] has checked the signature and that
/// the token belongs to this install, so editing a stored date — or copying
/// the token to another phone — yields no entitlement at all rather than a
/// better one.
class SignedEntitlement extends Equatable {
  const SignedEntitlement({
    required this.raw,
    required this.accountId,
    required this.installKey,
    required this.status,
    required this.sku,
    required this.until,
    required this.autoRenewing,
    required this.suspicious,
    required this.issuedAt,
    required this.policy,
  });

  /// The token exactly as the server sent it; what gets persisted.
  final String raw;
  final String accountId;
  final String installKey;
  final EntitlementStatus status;
  final String? sku;

  /// When access ends or ended. For [EntitlementStatus.refunded] this is the
  /// moment the refund took effect, not the period's original end.
  final DateTime? until;
  final bool autoRenewing;

  /// The account is in the conservative check mode (a refund before the
  /// paid period ended). Set and cleared by the server only.
  final bool suspicious;

  /// Server time the token was issued — also the last successful check.
  final DateTime issuedAt;
  final EntitlementPolicy policy;

  @override
  List<Object?> get props => [raw];
}

/// Checks a token's signature against the server's public keys and parses
/// it. Anything malformed, unsigned, signed by an unknown key, or bound to a
/// different install comes back as `null` — callers treat that exactly like
/// having no token.
class EntitlementVerifier {
  EntitlementVerifier(this._publicKeys, {Ed25519? algorithm})
    : _algorithm = algorithm ?? Ed25519();

  /// Server signing keys by key id. More than one so the server can rotate
  /// its key while installs that have not updated still verify.
  final Map<String, List<int>> _publicKeys;
  final Ed25519 _algorithm;

  static const _version = 'v1';

  /// Hard ceiling on what gets parsed, so a corrupt store can't make startup
  /// decode megabytes of JSON.
  static const _maxLength = 4096;

  Future<SignedEntitlement?> verify(
    String raw, {
    required String expectedInstallKey,
  }) async {
    if (raw.length > _maxLength) return null;
    final parts = raw.split('.');
    if (parts.length != 4 || parts[0] != _version) return null;
    final keyBytes = _publicKeys[parts[1]];
    if (keyBytes == null) return null;

    final List<int> payloadBytes;
    final List<int> signatureBytes;
    try {
      payloadBytes = _decode(parts[2]);
      signatureBytes = _decode(parts[3]);
    } on FormatException {
      return null;
    }
    if (signatureBytes.length != 64) return null;

    final signedPart = ascii.encode('${parts[0]}.${parts[1]}.${parts[2]}');
    final valid = await _algorithm.verify(
      signedPart,
      signature: Signature(
        signatureBytes,
        publicKey: SimplePublicKey(keyBytes, type: KeyPairType.ed25519),
      ),
    );
    if (!valid) return null;

    final Object? decoded;
    try {
      decoded = jsonDecode(utf8.decode(payloadBytes));
    } on FormatException {
      return null;
    }
    if (decoded is! Map<String, dynamic>) return null;
    final parsed = _parse(raw, decoded);
    if (parsed == null || parsed.installKey != expectedInstallKey) return null;
    return parsed;
  }

  static SignedEntitlement? _parse(String raw, Map<String, dynamic> json) {
    final sub = json['sub'];
    final ik = json['ik'];
    final status = EntitlementStatus.fromWire(json['st']);
    final sku = json['sku'];
    final until = json['until'];
    final ar = json['ar'] ?? false;
    final sus = json['sus'];
    final iat = json['iat'];
    final pol = json['pol'];
    if (sub is! String ||
        sub.isEmpty ||
        ik is! String ||
        status == null ||
        (sku != null && sku is! String) ||
        (until != null && until is! int) ||
        ar is! bool ||
        sus is! bool ||
        iat is! int ||
        pol is! Map<String, dynamic>) {
      return null;
    }
    // A running or ended subscription without an end date is not a state the
    // server produces; refuse it rather than guess which way it should fail.
    if (status != EntitlementStatus.none && until == null) return null;

    final policy = _parsePolicy(pol);
    if (policy == null) return null;

    return SignedEntitlement(
      raw: raw,
      accountId: sub,
      installKey: ik,
      status: status,
      sku: sku as String?,
      until: until == null
          ? null
          : DateTime.fromMillisecondsSinceEpoch(until as int, isUtc: true),
      autoRenewing: ar,
      suspicious: sus,
      issuedAt: DateTime.fromMillisecondsSinceEpoch(iat, isUtc: true),
      policy: policy,
    );
  }

  /// Bounds match the contract. A value outside them means the payload is
  /// not what the server meant to sign, so the whole token is refused.
  static EntitlementPolicy? _parsePolicy(Map<String, dynamic> json) {
    final graceH = json['graceH'];
    final refreshD = json['refreshD'];
    final susOfflineH = json['susOfflineH'];
    if (graceH is! int || graceH < 0 || graceH > 336) return null;
    if (refreshD is! int || refreshD < 0 || refreshD > 30) return null;
    if (susOfflineH is! int || susOfflineH < 1 || susOfflineH > 720) {
      return null;
    }
    return EntitlementPolicy(
      grace: Duration(hours: graceH),
      refreshWindow: Duration(days: refreshD),
      suspiciousOfflineLimit: Duration(hours: susOfflineH),
    );
  }

  static List<int> _decode(String value) =>
      base64Url.decode(base64Url.normalize(value));
}

/// The server's entitlement signing keys, compiled in at build time from the
/// same per-flavor file as the store billing key:
///
/// ```
/// --dart-define-from-file=billing.json
/// { "TARK_ENTITLEMENT_KEYS": "k1:<base64url Ed25519 public key>,k2:<…>" }
/// ```
///
/// Public keys only — the private halves never leave the server. A build
/// without any accepts no token, which is safe: it can never unlock premium
/// through the server, and it only ever runs monetized by mistake.
abstract final class EntitlementKeys {
  static const _raw = String.fromEnvironment('TARK_ENTITLEMENT_KEYS');

  static Map<String, List<int>> fromEnvironment() => parse(_raw);

  static Map<String, List<int>> parse(String raw) {
    final keys = <String, List<int>>{};
    for (final entry in raw.split(',')) {
      final separator = entry.indexOf(':');
      if (separator <= 0) continue;
      final kid = entry.substring(0, separator).trim();
      try {
        final bytes = base64Url.decode(
          base64Url.normalize(entry.substring(separator + 1).trim()),
        );
        if (bytes.length == 32) keys[kid] = bytes;
      } on FormatException {
        continue;
      }
    }
    return keys;
  }
}
