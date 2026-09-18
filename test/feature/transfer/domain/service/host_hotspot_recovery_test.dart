import 'package:flutter_test/flutter_test.dart';
import 'package:tark/feature/transfer/domain/service/host_hotspot_recovery.dart';

void main() {
  test('changed credentials are published before waiting for members', () {
    final machine = HostHotspotRecoveryMachine();
    machine.hotspotLost(generation: 1, membersExpected: 2);
    final rehosting = machine.beginRehost();
    final changed = machine.rehosted(
      generation: rehosting.generation,
      credentialRevision: 1,
    );

    expect(changed.phase, HostHotspotRecoveryPhase.credentialsChanged);
    expect(changed.isLive, isFalse);

    final waiting = machine.credentialsPublished(
      generation: rehosting.generation,
    );
    expect(waiting.phase, HostHotspotRecoveryPhase.waitingForMembers);
  });

  test(
    'socket rebound alone never says live; bidirectional peers restore it',
    () {
      final machine = HostHotspotRecoveryMachine();
      machine.hotspotLost(generation: 3, membersExpected: 2);
      final rehosting = machine.beginRehost();
      machine.rehosted(generation: rehosting.generation, credentialRevision: 4);
      machine.credentialsPublished(generation: rehosting.generation);

      final onePeer = machine.peerEvidence(
        generation: rehosting.generation,
        bidirectionallyReachable: 1,
      );
      expect(onePeer.isLive, isFalse);

      final restored = machine.peerEvidence(
        generation: rehosting.generation,
        bidirectionallyReachable: 2,
      );
      expect(restored.phase, HostHotspotRecoveryPhase.restored);
      expect(restored.isLive, isTrue);
    },
  );

  test('stale native callback cannot overwrite a newer reservation', () {
    final machine = HostHotspotRecoveryMachine();
    machine.hotspotLost(generation: 1, membersExpected: 1);
    final first = machine.beginRehost();
    machine.rehostFailed(generation: first.generation);
    final second = machine.beginRehost();

    final afterStale = machine.rehosted(
      generation: first.generation,
      credentialRevision: 99,
    );

    expect(afterStale.generation, second.generation);
    expect(afterStale.phase, HostHotspotRecoveryPhase.rehosting);
    expect(afterStale.credentialRevision, 0);
  });

  test('repeated failures are bounded', () {
    final machine = HostHotspotRecoveryMachine(maxAttempts: 2);
    machine.hotspotLost(generation: 1, membersExpected: 1);

    final first = machine.beginRehost();
    machine.rehostFailed(generation: first.generation);
    final second = machine.beginRehost();
    final failed = machine.rehostFailed(
      generation: second.generation,
      reason: 'reservation_refused',
    );

    expect(failed.phase, HostHotspotRecoveryPhase.failed);
    expect(failed.attempt, 2);
  });

  test('cancel is terminal and later callbacks are ignored', () {
    final machine = HostHotspotRecoveryMachine();
    machine.hotspotLost(generation: 2, membersExpected: 1);
    final rehosting = machine.beginRehost();
    final cancelled = machine.cancel();

    final lateCallback = machine.rehosted(
      generation: rehosting.generation,
      credentialRevision: 1,
    );

    expect(cancelled.phase, HostHotspotRecoveryPhase.cancelled);
    expect(lateCallback.phase, HostHotspotRecoveryPhase.cancelled);
  });

  test('no-member room restores after fresh credentials are published', () {
    final machine = HostHotspotRecoveryMachine();
    machine.hotspotLost(generation: 4, membersExpected: 0);
    final rehosting = machine.beginRehost();
    machine.rehosted(generation: rehosting.generation, credentialRevision: 2);

    final result = machine.credentialsPublished(
      generation: rehosting.generation,
    );

    expect(result.phase, HostHotspotRecoveryPhase.restored);
  });

  test('credentials must actually refresh after Android rehosts', () {
    final machine = HostHotspotRecoveryMachine();
    machine.hotspotLost(generation: 1, membersExpected: 1);
    final rehosting = machine.beginRehost();

    final result = machine.rehosted(
      generation: rehosting.generation,
      credentialRevision: 0,
    );

    expect(result.phase, HostHotspotRecoveryPhase.failed);
    expect(result.reason, 'credentials_not_refreshed');
  });
}
