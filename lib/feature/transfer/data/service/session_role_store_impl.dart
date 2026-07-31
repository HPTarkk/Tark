import 'package:injectable/injectable.dart';

import '../../domain/entity/session_role.dart';
import '../../domain/service/session_role_store.dart';

@LazySingleton(as: SessionRoleStore)
class SessionRoleStoreImpl implements SessionRoleStore {
  SessionRole? _role;

  @override
  SessionRole? get role => _role;

  @override
  void setRole(SessionRole role) => _role = role;

  @override
  void clear() => _role = null;
}
