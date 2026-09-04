import 'dart:async';

import 'package:dartz/dartz.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tark/core/audio/audio_format_profile.dart';
import 'package:tark/core/error/failure.dart';
import 'package:tark/core/utils/exponential_backoff.dart';
import 'package:tark/feature/transfer/data/service/hotspot_link_keeper_impl.dart';
import 'package:tark/feature/transfer/domain/entity/audio_profile.dart';
import 'package:tark/feature/transfer/domain/entity/connection_health.dart';
import 'package:tark/feature/transfer/domain/entity/hotspot_credentials.dart';
import 'package:tark/feature/transfer/domain/entity/session_role.dart';
import 'package:tark/feature/transfer/domain/entity/transport_stats.dart';
import 'package:tark/feature/transfer/domain/entity/waki_packet.dart';
import 'package:tark/feature/transfer/domain/repository/wifi_transfer_repository.dart';
import 'package:tark/feature/transfer/domain/service/hotspot_control.dart';
import 'package:tark/feature/transfer/domain/service/hotspot_link_keeper.dart';
import 'package:tark/feature/transfer/domain/service/session_role_store.dart';

const _creds = HotspotCredentials(ssid: 'AndroidShare_1865', passphrase: 'abc');

class _FakeHost implements HotspotHost {

  @override
  bool get isHosting => starts > 0;
  final _stopped = StreamController<void>.broadcast();
  int starts = 0;
  HotspotCredentials next = const HotspotCredentials(
    ssid: 'AndroidShare_9999',
    passphrase: 'xyz',
  );
  Object? startError;

  void tearDown() => _stopped.add(null);

  @override
  Stream<void> get onStopped => _stopped.stream;

  @override
  Future<HotspotCredentials> start() async {
    starts++;
    if (startError != null) throw startError!;
    return next;
  }

  @override
  Future<void> stop() async {}

  @override
  Future<void> openFixSettings(String errorCode) async {}

  @override
  Future<HotspotWifiAdvice> wifiAdvice() async => HotspotWifiAdvice.none;

  @override
  Future<bool> openWifiPanel() async => false;
}

class _FakeJoiner implements HotspotJoiner {
  final _lost = StreamController<void>.broadcast();
  final _rebound = StreamController<void>.broadcast();
  final List<HotspotCredentials> joins = [];
  List<HotspotJoinResult> results = [HotspotJoinResult.joined];

  void drop() => _lost.add(null);
  void rebound() => _rebound.add(null);

  @override
  Stream<void> get onLost => _lost.stream;

  @override
  Stream<void> get onRebound => _rebound.stream;

  @override
  Future<HotspotJoinResult> join(HotspotCredentials credentials) async {
    joins.add(credentials);
    return results.length > 1 ? results.removeAt(0) : results.first;
  }

  @override
  Future<bool> enableWifi() async => false;

  @override
  Future<void> openLocationSettings() async {}

  @override
  Future<bool> bindToCurrentWifi() async => false;

  @override
  Future<void> leave() async {}
}

class _FakeWifi implements WifiTransferRepository {
  int rebinds = 0;
  TransportStats currentStats = TransportStats.none;

  @override
  void rebindSockets() => rebinds++;

  @override
  SessionRole get sessionRole => SessionRole.joiner;

  @override
  Stream<WakiPacket> startListening() => const Stream<WakiPacket>.empty();

  @override
  Stream<ConnectionHealth> connect() => const Stream<ConnectionHealth>.empty();

  @override
  TransportStats get stats => currentStats;

  @override
  Future<Either<Failure, void>> sendAudio(
    List<double> samples,
    String senderName,
  ) async => const Right(null);

  @override
  Future<Either<Failure, void>> sendMedia(
    List<double> samples,
    String senderName,
  ) async => const Right(null);

  @override
  Future<Either<Failure, void>> sendPresence(
    String senderName,
    bool isTalking, {
    bool isLeaving = false,
  }) async => const Right(null);

  @override
  void stopConnection() {}

  @override
  void setAutoReconnectEnabled(bool enabled) {}

  @override
  void retryNow() {}

  @override
  void setAudioProfile(AudioProfile profile) {}

  @override
  void resetCodecState() {}

  @override
  AudioFormatProfile get negotiatedFormat => AudioFormatProfile.legacy16k;

  @override
  AudioFormatProfile? get negotiatedMediaFormat => null;

  @override
  void repairSendPath() {}

  @override
  void dispose() {}
}

class _FakeRoleStore implements SessionRoleStore {
  @override
  SessionRole? role;

  @override
  void setRole(SessionRole value) => role = value;

  @override
  void clear() => role = null;
}

void main() {
  late _FakeHost host;
  late _FakeJoiner joiner;
  late _FakeRoleStore roles;
  late _FakeWifi wifi;
  late HotspotLinkKeeper keeper;

  HotspotLinkKeeper buildKeeper({
    Duration recoveryTimeout = const Duration(minutes: 10),
  }) => HotspotLinkKeeperImpl(
    host,
    joiner,
    roles,
    wifi,
    recoveryTimeout: recoveryTimeout,
    hostEvidenceInterval: const Duration(milliseconds: 5),
    backoffFactory: () => ExponentialBackoff(
      initial: const Duration(milliseconds: 5),
      max: const Duration(milliseconds: 5),
    ),
  );

  setUp(() {
    host = _FakeHost();
    joiner = _FakeJoiner();
    roles = _FakeRoleStore();
    wifi = _FakeWifi();
    keeper = buildKeeper();
  });

  tearDown(() => keeper.dispose());

  group('as a joiner', () {
    setUp(() => roles.role = SessionRole.joiner);

    test('rejoins with the adopted credentials when the link drops', () async {
      keeper.adopt(_creds);
      joiner.drop();
      await pumpEventQueue();

      expect(joiner.joins, [_creds]);
      expect(keeper.state, HotspotLinkState.up);
      expect(wifi.rebinds, 1);
    });

    test('reports recovering while a rejoin is in flight', () async {
      keeper.adopt(_creds);
      final seen = <HotspotLinkState>[];
      final sub = keeper.states.listen(seen.add);

      joiner.drop();
      await pumpEventQueue();

      expect(
        seen,
        containsAllInOrder([HotspotLinkState.recovering, HotspotLinkState.up]),
      );
      await sub.cancel();
    });

    test('release abandons a recovery instead of rejoining later', () async {
      joiner.results = [HotspotJoinResult.declined];
      keeper.adopt(_creds);
      joiner.drop();
      await pumpEventQueue();

      final attemptsBefore = joiner.joins.length;
      await keeper.release();
      await Future<void>.delayed(const Duration(milliseconds: 30));

      expect(joiner.joins, hasLength(attemptsBefore));
      expect(keeper.state, HotspotLinkState.idle);
    });

    test(
      'gives up after the bounded recovery timeout and retry works',
      () async {
        joiner.results = [HotspotJoinResult.declined];
        keeper = buildKeeper(recoveryTimeout: const Duration(milliseconds: 20));
        keeper.adopt(_creds);
        joiner.drop();
        await Future<void>.delayed(const Duration(milliseconds: 60));
        expect(keeper.state, HotspotLinkState.lost);

        joiner.results = [HotspotJoinResult.joined];
        keeper.retryNow();
        await pumpEventQueue();

        expect(keeper.state, HotspotLinkState.up);
        expect(wifi.rebinds, 1);
      },
    );

    test('OS rebound repairs sockets without starting another join', () async {
      keeper.adopt(_creds);
      joiner.rebound();
      await pumpEventQueue();

      expect(wifi.rebinds, 1);
      expect(joiner.joins, isEmpty);
      expect(keeper.state, HotspotLinkState.up);
    });

    test('drop after release is ignored', () async {
      keeper.adopt(_creds);
      await keeper.release();
      joiner.drop();
      await pumpEventQueue();

      expect(joiner.joins, isEmpty);
    });
  });

  group('as a host', () {
    setUp(() => roles.role = SessionRole.host);

    test(
      'publishes fresh credentials and rebinds after Android re-hosts',
      () async {
        final fresh = <HotspotCredentials>[];
        final sub = keeper.credentialChanges.listen(fresh.add);
        keeper.adopt(_creds);

        host.tearDown();
        await pumpEventQueue();

        expect(host.starts, 1);
        expect(fresh, [host.next]);
        expect(keeper.credentials, host.next);
        expect(wifi.rebinds, 1);
        // No peers were present before the loss, so fresh credentials are enough
        // to restore this solo attachment.
        expect(keeper.state, HotspotLinkState.up);
        await sub.cancel();
      },
    );

    test(
      'does not claim Live until the pre-loss peer is bidirectional again',
      () async {
        wifi.currentStats = const TransportStats(peerCount: 1);
        keeper.adopt(_creds);

        host.tearDown();
        await pumpEventQueue();

        expect(keeper.state, HotspotLinkState.recovering);
        expect(keeper.credentials, host.next);

        // Merely hearing the peer is insufficient: no matched ping/RTT yet.
        wifi.currentStats = const TransportStats(peerCount: 1);
        await Future<void>.delayed(const Duration(milliseconds: 15));
        expect(keeper.state, HotspotLinkState.recovering);

        wifi.currentStats = const TransportStats(
          peerCount: 1,
          rtt: Duration(milliseconds: 12),
        );
        await Future<void>.delayed(const Duration(milliseconds: 15));

        expect(keeper.state, HotspotLinkState.up);
      },
    );

    test(
      'unicast-unconfirmed evidence keeps a re-hosted AP recovering',
      () async {
        wifi.currentStats = const TransportStats(peerCount: 1);
        keeper.adopt(_creds);
        host.tearDown();
        await pumpEventQueue();

        wifi.currentStats = const TransportStats(
          peerCount: 1,
          rtt: Duration(milliseconds: 10),
          unicastUnconfirmed: true,
        );
        await Future<void>.delayed(const Duration(milliseconds: 15));

        expect(keeper.state, HotspotLinkState.recovering);
      },
    );

    test('release cancels peer-evidence waiting exactly once', () async {
      wifi.currentStats = const TransportStats(peerCount: 1);
      keeper.adopt(_creds);
      host.tearDown();
      await pumpEventQueue();
      expect(keeper.state, HotspotLinkState.recovering);

      await keeper.release();
      wifi.currentStats = const TransportStats(
        peerCount: 1,
        rtt: Duration(milliseconds: 10),
      );
      await Future<void>.delayed(const Duration(milliseconds: 15));

      expect(keeper.state, HotspotLinkState.idle);
    });

    test(
      'host retry republishes current fresh credentials after peer timeout',
      () async {
        wifi.currentStats = const TransportStats(peerCount: 1);
        keeper = buildKeeper(recoveryTimeout: const Duration(milliseconds: 20));
        final fresh = <HotspotCredentials>[];
        final sub = keeper.credentialChanges.listen(fresh.add);
        keeper.adopt(_creds);
        host.tearDown();
        await Future<void>.delayed(const Duration(milliseconds: 50));
        expect(keeper.state, HotspotLinkState.lost);
        expect(fresh, [host.next]);

        keeper.retryNow();
        await pumpEventQueue();

        expect(keeper.state, HotspotLinkState.recovering);
        expect(fresh, [host.next, host.next]);
        expect(
          host.starts,
          1,
          reason: 'valid re-hosted AP is reused, not replaced',
        );
        await sub.cancel();
      },
    );

    test('re-host failures are bounded and end in lost', () async {
      host.startError = StateError('no channel');
      keeper = buildKeeper(recoveryTimeout: const Duration(milliseconds: 100));
      keeper.adopt(_creds);

      host.tearDown();
      await Future<void>.delayed(const Duration(milliseconds: 60));

      expect(host.starts, 4);
      expect(keeper.state, HotspotLinkState.lost);
    });

    test('does not listen on the joiner side', () async {
      keeper.adopt(_creds);
      joiner.drop();
      await pumpEventQueue();

      expect(joiner.joins, isEmpty);
    });
  });

  group('with no side claimed', () {
    test('plain Wi-Fi adopts nothing to recover', () async {
      roles.role = SessionRole.peer;
      keeper.adopt(_creds);

      joiner.drop();
      host.tearDown();
      await pumpEventQueue();

      expect(joiner.joins, isEmpty);
      expect(host.starts, 0);
    });
  });
}
