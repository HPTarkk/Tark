import '../entity/session_role.dart';

/// The side this device took in the current Wi-Fi session.
///
/// Only Wi-Fi needs telling. Bluetooth and the guest link know which end they
/// are from the connection itself, but a hotspot host and the phone that
/// joined its AP both end up running the same plain UDP over the same subnet
/// — the difference lives in the bridge screen that set the session up, not
/// in the transport. Session-scoped, never persisted: which side you took
/// last time says nothing about this time.
abstract interface class SessionRoleStore {
  /// Null when nobody claimed a side — plain Wi-Fi through a router, where
  /// there is no host to be.
  SessionRole? get role;

  void setRole(SessionRole role);

  void clear();
}
