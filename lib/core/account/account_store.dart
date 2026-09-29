import 'dart:convert';

import '../network/authenticated_api_client.dart';
import '../security/app_secure_storage.dart';
import '../utils/logger.dart';
import 'account_models.dart';

/// Everything the account keeps on this phone, all of it in
/// [AppSecureStorage] (Android Keystore): the token pair, the last profile
/// the server sent (so the signed-in state shows offline), started email
/// flows (so a link can finish one after the app was closed), and whether a
/// local profile edit still has to reach the server.
///
/// Reads that fail are treated as absent; see [AppSecureStorage].
class AccountStore implements TokenVault {
  AccountStore(this._storage);

  final AppSecureStorage _storage;

  static const _tokensKey = 'account_tokens';
  static const _profileKey = 'account_profile';
  static const _profileDirtyKey = 'account_profile_dirty';
  static String _flowKey(FlowKind kind) => 'account_flow_${kind.name}';

  @override
  Future<SessionTokens?> readTokens() async {
    final json = await _readJson(_tokensKey);
    return json == null ? null : SessionTokens.fromJson(json);
  }

  @override
  Future<void> writeTokens(SessionTokens tokens) =>
      _storage.write(_tokensKey, jsonEncode(tokens.toJson()));

  @override
  Future<void> clearTokens() => _storage.delete(_tokensKey);

  Future<AccountProfile?> readProfile() async =>
      AccountProfile.fromJson(await _readJson(_profileKey));

  Future<void> writeProfile(AccountProfile profile) =>
      _storage.write(_profileKey, jsonEncode(profile.toJson()));

  Future<PendingFlow?> readFlow(FlowKind kind) async {
    final json = await _readJson(_flowKey(kind));
    return json == null ? null : PendingFlow.fromStored(json);
  }

  Future<void> writeFlow(PendingFlow flow) =>
      _storage.write(_flowKey(flow.kind), jsonEncode(flow.toStored()));

  Future<void> clearFlow(FlowKind kind) => _safeDelete(_flowKey(kind));

  Future<bool> isProfileDirty() async {
    try {
      return await _storage.read(_profileDirtyKey) == '1';
    } catch (_) {
      return false;
    }
  }

  Future<void> setProfileDirty(bool dirty) async {
    try {
      if (dirty) {
        await _storage.write(_profileDirtyKey, '1');
      } else {
        await _storage.delete(_profileDirtyKey);
      }
    } catch (error) {
      Logger.log('Account: could not store profile sync flag ($error)');
    }
  }

  /// Everything but started flows: used on sign-out and when the session
  /// ends.
  Future<void> clearAccount() async {
    await _safeDelete(_tokensKey);
    await _safeDelete(_profileKey);
    await _safeDelete(_profileDirtyKey);
  }

  Future<Map<String, dynamic>?> _readJson(String key) async {
    try {
      final raw = await _storage.read(key);
      if (raw == null) return null;
      final decoded = jsonDecode(raw);
      return decoded is Map<String, dynamic> ? decoded : null;
    } catch (error) {
      Logger.log('Account: stored $key unreadable ($error)');
      return null;
    }
  }

  Future<void> _safeDelete(String key) async {
    try {
      await _storage.delete(key);
    } catch (error) {
      Logger.log('Account: could not delete $key ($error)');
    }
  }
}
