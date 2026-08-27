import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:tark/feature/room/domain/entity/room.dart';
import 'package:tark/feature/room/domain/service/room_failover_controller.dart';
import 'package:tark/feature/room/domain/service/room_failover_runtime.dart';
import 'package:tark/feature/room/domain/service/room_failover_transport_orchestrator.dart';
import 'package:tark/feature/room/domain/service/room_live_failover_transport_starter.dart';
import 'package:tark/feature/room/domain/service/room_transport_planner.dart';
import 'package:tark/feature/transfer/domain/entity/connection_health.dart';
import 'package:tark/feature/transfer/domain/entity/hotspot_credentials.dart';
import 'package:tark/feature/transfer/domain/entity/transfer_mode.dart';
import 'package:tark/feature/transfer/domain/repository/transfer_repository.dart';
import 'package:tark/feature/transfer/domain/service/hotspot_control.dart';
import 'package:tark/feature/transfer/domain/service/hotspot_link_keeper.dart';
import 'package:tark/feature/transfer/domain/service/transfer_mode_store.dart';

void main() {
  const local = RoomMemberId('aaaaaaaaaaaaaaaaaaaaaaaa');
  const remote = RoomMemberId('bbbbbbbbbbbbbbbbbbbbbbbb');

  RoomFailoverTransportContext contextFor({required RoomTransportPlan plan}) {
    final decision = RoomFailoverDecision(
      epoch: plan.epoch,
      plan: plan,
      reason: RoomFailoverReason.hostLost,
      requiresUserRescan: plan.kind == RoomTransportKind.hotspot,
    );
    return RoomFailoverTransportContext(
      attempt: RoomFailoverAttempt(decision: decision, attachmentGeneration: 2),
      callbacks: RoomFailoverTransportCallbacks(
        ready: ({String? role}) => true,
        degraded: ({String? reason}) => true,
        failed: ({String? reason}) => true,
      ),
    );
  }

  test('local elected hotspot host starts and owns real hotspot', () async {
    final modes = _ModeStore();
    final transfer = _Transfer();
    final host = _HotspotHost();
    final keeper = _HotspotKeeper();
    final starter = RoomLiveFailoverTransportStarter(
      localMemberId: local,
      modeStore: modes,
      transfer: transfer,
      hotspotHost: host,
      hotspotLinkKeeper: keeper,
    );
    final context = contextFor(
      plan: const RoomTransportPlan(
        epoch: 3,
        kind: RoomTransportKind.hotspot,
        reason: RoomTransportPlanReason.deterministicHotspotHost,
        hotspotHost: local,
      ),
    );

    final handle = await starter.call(context);

    expect(host.startCalls, 1);
    expect(keeper.adopted, host.credentials);
    expect(modes.mode, TransferMode.hotspot);
    expect(transfer.connectCalls, 1);

    await handle.dispose();
    expect(host.stopCalls, 1);
    expect(keeper.releaseCalls, 1);
    expect(transfer.health.hasListener, isFalse);
    await transfer.disposeController();
    modes.dispose();
  });

  test(
    'remote hotspot winner never starts a competing local hotspot',
    () async {
      final modes = _ModeStore();
      final transfer = _Transfer();
      final host = _HotspotHost();
      final keeper = _HotspotKeeper();
      String? degradedReason;
      final starter = RoomLiveFailoverTransportStarter(
        localMemberId: local,
        modeStore: modes,
        transfer: transfer,
        hotspotHost: host,
        hotspotLinkKeeper: keeper,
      );
      final decision = RoomFailoverDecision(
        epoch: 4,
        plan: const RoomTransportPlan(
          epoch: 4,
          kind: RoomTransportKind.hotspot,
          reason: RoomTransportPlanReason.deterministicHotspotHost,
          hotspotHost: remote,
        ),
        reason: RoomFailoverReason.hostLost,
        requiresUserRescan: true,
      );
      final context = RoomFailoverTransportContext(
        attempt: RoomFailoverAttempt(
          decision: decision,
          attachmentGeneration: 3,
        ),
        callbacks: RoomFailoverTransportCallbacks(
          ready: ({String? role}) => true,
          degraded: ({String? reason}) {
            degradedReason = reason;
            return true;
          },
          failed: ({String? reason}) => true,
        ),
      );

      final handle = await starter.call(context);

      expect(host.startCalls, 0);
      expect(keeper.adopted, isNull);
      expect(modes.mode, TransferMode.hotspot);
      expect(degradedReason, 'failover_waiting_for_remote_hotspot_rejoin');

      await handle.dispose();
      expect(host.stopCalls, 0);
      expect(keeper.releaseCalls, 0);
      await transfer.disposeController();
      modes.dispose();
    },
  );

  test(
    'replacement health is translated to generation-gated callbacks',
    () async {
      final modes = _ModeStore();
      final transfer = _Transfer();
      final host = _HotspotHost();
      final keeper = _HotspotKeeper();
      String? readyRole;
      final degraded = <String?>[];
      final failed = <String?>[];
      final starter = RoomLiveFailoverTransportStarter(
        localMemberId: local,
        modeStore: modes,
        transfer: transfer,
        hotspotHost: host,
        hotspotLinkKeeper: keeper,
      );
      final decision = RoomFailoverDecision(
        epoch: 5,
        plan: const RoomTransportPlan(
          epoch: 5,
          kind: RoomTransportKind.sharedLan,
          reason: RoomTransportPlanReason.usableSharedLan,
        ),
        reason: RoomFailoverReason.transportFailed,
        requiresUserRescan: false,
      );
      final context = RoomFailoverTransportContext(
        attempt: RoomFailoverAttempt(
          decision: decision,
          attachmentGeneration: 4,
        ),
        callbacks: RoomFailoverTransportCallbacks(
          ready: ({String? role}) {
            readyRole = role;
            return true;
          },
          degraded: ({String? reason}) {
            degraded.add(reason);
            return true;
          },
          failed: ({String? reason}) {
            failed.add(reason);
            return true;
          },
        ),
      );

      final handle = await starter.call(context);
      transfer.health.add(const ConnectionHealth.reconnecting());
      transfer.health.add(const ConnectionHealth.healthy());
      transfer.health.add(const ConnectionHealth.down());

      expect(modes.mode, TransferMode.wifi);
      expect(degraded, [ConnectionHealthStatus.reconnecting.name]);
      expect(readyRole, 'peer');
      expect(failed, ['replacement_transport_down']);

      await handle.dispose();
      await transfer.disposeController();
      modes.dispose();
    },
  );

  test(
    'hotspot start failure does not claim ownership or change mode',
    () async {
      final modes = _ModeStore(initial: TransferMode.wifi);
      final transfer = _Transfer();
      final host = _HotspotHost(failStart: true);
      final keeper = _HotspotKeeper();
      final starter = RoomLiveFailoverTransportStarter(
        localMemberId: local,
        modeStore: modes,
        transfer: transfer,
        hotspotHost: host,
        hotspotLinkKeeper: keeper,
      );
      final context = contextFor(
        plan: const RoomTransportPlan(
          epoch: 6,
          kind: RoomTransportKind.hotspot,
          reason: RoomTransportPlanReason.deterministicHotspotHost,
          hotspotHost: local,
        ),
      );

      await expectLater(starter.call(context), throwsStateError);

      expect(host.startCalls, 1);
      expect(host.stopCalls, 0);
      expect(keeper.adopted, isNull);
      expect(modes.mode, TransferMode.wifi);
      expect(transfer.connectCalls, 0);
      await transfer.disposeController();
      modes.dispose();
    },
  );
}

final class _ModeStore implements TransferModeStore {
  _ModeStore({TransferMode initial = TransferMode.wifi}) : _mode = initial;

  TransferMode _mode;
  final _changes = StreamController<TransferMode>.broadcast(sync: true);

  @override
  TransferMode get mode => _mode;

  @override
  Stream<TransferMode> get modeChanges => _changes.stream;

  @override
  Future<void> setMode(TransferMode mode) async {
    _mode = mode;
    _changes.add(mode);
  }

  void dispose() => _changes.close();

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

final class _Transfer implements TransferRepository {
  final health = StreamController<ConnectionHealth>.broadcast(sync: true);
  int connectCalls = 0;

  @override
  Stream<ConnectionHealth> connect() {
    connectCalls += 1;
    return health.stream;
  }

  Future<void> disposeController() => health.close();

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

final class _HotspotHost implements HotspotHost {
  _HotspotHost({this.failStart = false});

  final bool failStart;
  final credentials = const HotspotCredentials(
    ssid: 'Tark-Test',
    passphrase: 'test-passphrase',
  );
  int startCalls = 0;
  int stopCalls = 0;

  @override
  Future<HotspotCredentials> start() async {
    startCalls += 1;
    if (failStart) throw StateError('hotspot unavailable');
    return credentials;
  }

  @override
  Future<void> stop() async {
    stopCalls += 1;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

final class _HotspotKeeper implements HotspotLinkKeeper {
  HotspotCredentials? adopted;
  int releaseCalls = 0;

  @override
  void adopt(HotspotCredentials credentials) {
    adopted = credentials;
  }

  @override
  Future<void> release() async {
    releaseCalls += 1;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
