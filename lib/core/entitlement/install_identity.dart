import 'dart:convert';

import 'package:cryptography/cryptography.dart';

import '../security/app_secure_storage.dart';
import '../utils/logger.dart';

/// This install's own Ed25519 key pair, created once and kept in secure
/// storage. The server binds every entitlement to its public half, so a
/// token lifted from one phone does not verify on another.
///
/// Reinstalling makes a new key; that is fine — the account, not the key,
/// owns the subscription, and the first check after a reinstall simply
/// issues a token for the new key.
class InstallIdentity {
  InstallIdentity(this._storage, {Ed25519? algorithm})
    : _algorithm = algorithm ?? Ed25519();

  final AppSecureStorage _storage;
  final Ed25519 _algorithm;

  static const _storageKey = 'install_key';

  SimpleKeyPair? _keyPair;
  String? _publicKey;

  /// base64url, no padding — the `X-Tark-Install-Key` header value and the
  /// `ik` a valid entitlement must carry.
  String get publicKey {
    final key = _publicKey;
    if (key == null) throw StateError('InstallIdentity used before load()');
    return key;
  }

  Future<void> load() async {
    if (_keyPair != null) return;
    String? stored;
    var persist = true;
    try {
      stored = await _storage.read(_storageKey);
    } catch (error) {
      if (isSecureStorageUnavailable(error)) {
        // The stored key is still there, the Keystore just could not open it
        // right now. A key for this run only keeps the app working; writing
        // it would throw away a key that reads fine next launch.
        persist = false;
        Logger.log('InstallIdentity: secure storage busy, one-run key ($error)');
      } else {
        // Unreadable is treated as absent: a fresh key only costs one online
        // check, while trusting a half-read key could cost the entitlement.
        Logger.log('InstallIdentity: stored key unreadable, replacing ($error)');
      }
    }

    SimpleKeyPair? pair;
    if (stored != null) {
      try {
        final seed = base64Url.decode(base64Url.normalize(stored));
        if (seed.length == 32) {
          pair = await _algorithm.newKeyPairFromSeed(seed);
        }
      } on FormatException {
        pair = null;
      }
    }
    if (pair == null) {
      pair = await _algorithm.newKeyPair();
      if (persist) {
        final seed = await pair.extractPrivateKeyBytes();
        await _storage.write(_storageKey, _encode(seed));
      }
    }
    final publicKey = await pair.extractPublicKey();
    _keyPair = pair;
    _publicKey = _encode(publicKey.bytes);
  }

  /// Signs [message] with the install key, for requests that must prove
  /// they come from this install.
  Future<List<int>> sign(List<int> message) async {
    final pair = _keyPair;
    if (pair == null) throw StateError('InstallIdentity used before load()');
    final signature = await _algorithm.sign(message, keyPair: pair);
    return signature.bytes;
  }

  static String _encode(List<int> bytes) =>
      base64Url.encode(bytes).replaceAll('=', '');
}
