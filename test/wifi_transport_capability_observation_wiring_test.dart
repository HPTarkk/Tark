import 'package:flutter_test/flutter_test.dart';
import 'package:tark/core/identity/channel_membership.dart';
import 'package:tark/core/identity/device_identity.dart';
import 'package:tark/core/identity/session_epoch.dart';
import 'package:tark/feature/transfer/data/repository/wifi_transfer_repository_impl.dart';
import 'package:tark/feature/transfer/domain/entity/session_role.dart';
import 'package:tark/feature/transfer/domain/repository/transport_capability_observation_source.dart';
import 'package:tark/feature/transfer/domain/service/session_role_store.dart';

void main() {
  test('wifi exposes capability source without fabricating peer evidence', () async {
    final repository = WifiTransferRepositoryImpl(
      const DeviceIdentity.withId('0123456789ab'),
      SessionEpoch.startingAt(7),
      _RoleStore(),
      ChannelMembership(),
    );

    expect(repository, isA<TransportCapabilityObservationSource>());
    var observed = false;
    final subscription = repository.transportCapabilityObservations.listen((_) {
      observed = true;
    });
    await Future<void>.delayed(Duration.zero);
    expect(observed, isFalse);
    await subscription.cancel();
    repository.dispose();
  });
}

final class _RoleStore implements SessionRoleStore {
  SessionRole? _role;

  @override
  SessionRole? get role => _role;

  @override
  void setRole(SessionRole role) => _role = role;

  @override
  void clear() => _role = null;
}
