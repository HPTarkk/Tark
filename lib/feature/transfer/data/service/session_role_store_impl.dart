import 'dart:async';

import 'package:injectable/injectable.dart';

import '../../domain/entity/session_role.dart';
import '../../domain/service/session_role_store.dart';

@LazySingleton(as: SessionRoleStore)
class SessionRoleStoreImpl
    implements SessionRoleStore, SessionRoleChangeSource {
  SessionRole? _role;
  final StreamController<SessionRole?> _changes =
      StreamController<SessionRole?>.broadcast(sync: true);

  @override
  SessionRole? get role => _role;

  @override
  Stream<SessionRole?> get roleChanges => _changes.stream;

  @override
  void setRole(SessionRole role) {
    if (_role == role) return;
    _role = role;
    _changes.add(role);
  }

  @override
  void clear() {
    if (_role == null) return;
    _role = null;
    _changes.add(null);
  }
}
