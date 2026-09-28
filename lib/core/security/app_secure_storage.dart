import 'package:flutter/services.dart';

/// String storage for app secrets — never SharedPreferences, never plaintext
/// on disk. Keys are short lowercase identifiers (`[a-z][a-z0-9_]*`).
///
/// Reads that fail (a corrupt entry, a Keystore that refuses) throw: callers
/// decide what "unreadable" means for their data, and for everything stored
/// here the safe answer is "treat it as absent", never "fall back to a copy".
abstract interface class AppSecureStorage {
  Future<String?> read(String key);
  Future<void> write(String key, String value);
  Future<void> delete(String key);
}

/// Android Keystore AES-GCM behind `tark/app_secure_storage` — see
/// AppSecureStorageHandler.kt. Android only: the paid features, and so
/// everything that needs this, exist only there for now.
final class PlatformAppSecureStorage implements AppSecureStorage {
  PlatformAppSecureStorage({MethodChannel? channel})
    : _channel = channel ?? const MethodChannel('tark/app_secure_storage');

  final MethodChannel _channel;

  @override
  Future<String?> read(String key) =>
      _channel.invokeMethod<String>('read', {'key': key});

  @override
  Future<void> write(String key, String value) =>
      _channel.invokeMethod<void>('write', {'key': key, 'value': value});

  @override
  Future<void> delete(String key) =>
      _channel.invokeMethod<void>('delete', {'key': key});
}

/// Process-lifetime storage for platforms without a native store and for
/// tests. Nothing survives a restart, which on those platforms is correct:
/// they never run monetized.
final class MemoryAppSecureStorage implements AppSecureStorage {
  final Map<String, String> _values = {};

  @override
  Future<String?> read(String key) async => _values[key];

  @override
  Future<void> write(String key, String value) async => _values[key] = value;

  @override
  Future<void> delete(String key) async => _values.remove(key);
}
