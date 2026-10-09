import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tark/core/entitlement/install_identity.dart';
import 'package:tark/core/security/app_secure_storage.dart';

/// Secure storage whose reads fail with a chosen platform error code.
final class _FailingReads implements AppSecureStorage {
  _FailingReads(this.code);

  final String code;
  final Map<String, String> writes = {};

  @override
  Future<String?> read(String key) async =>
      throw PlatformException(code: code);

  @override
  Future<void> write(String key, String value) async => writes[key] = value;

  @override
  Future<void> delete(String key) async => writes.remove(key);
}

void main() {
  test('a stored key is reused across loads', () async {
    final storage = MemoryAppSecureStorage();
    final first = InstallIdentity(storage);
    await first.load();
    final second = InstallIdentity(storage);
    await second.load();
    expect(second.publicKey, first.publicKey);
  });

  test('a temporarily unavailable store is never written over', () async {
    final storage = _FailingReads('secure_storage_unavailable');
    final identity = InstallIdentity(storage);
    await identity.load();
    expect(identity.publicKey, isNotEmpty); // still usable this run
    expect(storage.writes, isEmpty); // the stored key survives
  });

  test('an unreadable (removed) entry is replaced with a new key', () async {
    final storage = _FailingReads('secure_storage_failed');
    final identity = InstallIdentity(storage);
    await identity.load();
    expect(storage.writes.keys, ['install_key']);
  });

  test('only the unavailable code counts as temporary', () {
    expect(
      isSecureStorageUnavailable(
        PlatformException(code: 'secure_storage_unavailable'),
      ),
      isTrue,
    );
    expect(
      isSecureStorageUnavailable(
        PlatformException(code: 'secure_storage_failed'),
      ),
      isFalse,
    );
    expect(isSecureStorageUnavailable(StateError('x')), isFalse);
  });
}
