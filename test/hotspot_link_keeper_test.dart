import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:tark/feature/transfer/data/service/hotspot_link_keeper_impl.dart';
import 'package:tark/feature/transfer/domain/entity/hotspot_credentials.dart';
import 'package:tark/feature/transfer/domain/entity/session_role.dart';
import 'package:tark/feature/transfer/domain/service/hotspot_control.dart';
import 'package:tark/feature/transfer/domain/service/hotspot_link_keeper.dart';
import 'package:tark/feature/transfer/domain/service/session_role_store.dart';

const _creds = HotspotCredentials(ssid: 'AndroidShare_1865', passphrase: 'abc');

class _FakeHost implements HotspotHost {
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
}

class _FakeJoiner implements HotspotJoiner {
  final _lost = StreamController<void>.broadcast();
  final List<HotspotCredentials> joins = [];

  /// Results handed out in order; the last one repeats.
  List<HotspotJoinResult> results = [HotspotJoinResult.joined];

  void drop() => _lost.add(null);

  @override
  Stream<void> get onLost => _lost.stream;

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
  late HotspotLinkKeeper keeper;

  setUp(() {
    host = _FakeHost();
    joiner = _FakeJoiner();
    roles = _FakeRoleStore();
    keeper = HotspotLinkKeeperImpl(host, joiner, roles);
  });

  tearDown(() => keeper.dispose());

  group('as a joiner', () {
    setUp(() => roles.role = SessionRole.joiner);

    test('rejoins with the adopted credentials when the link drops', () async {
      keeper.adopt(_creds);
      expect(keeper.state, HotspotLinkState.up);

      joiner.drop();
      await pumpEventQueue();

      // The whole point: nobody was listening for this once the pairing screen
      // was gone, so a phone pulled off the hotspot stayed off it.
      expect(joiner.joins, [_creds]);
      expect(keeper.state, HotspotLinkState.up);
    });

    test('reports recovering while a rejoin is in flight', () async {
      keeper.adopt(_creds);
      final seen = <HotspotLinkState>[];
      keeper.states.listen(seen.add);

      joiner.drop();
      await pumpEventQueue();

      expect(seen, containsAllInOrder([
        HotspotLinkState.recovering,
        HotspotLinkState.up,
      ]));
    });

    test('stays in recovery when the rejoin is refused', () async {
      joiner.results = [HotspotJoinResult.declined];
      keeper.adopt(_creds);

      joiner.drop();
      await pumpEventQueue();

      expect(keeper.state, HotspotLinkState.recovering);
      expect(joiner.joins, isNotEmpty);
    });

    test('release abandons a recovery instead of rejoining later', () async {
      joiner.results = [HotspotJoinResult.declined];
      keeper.adopt(_creds);
      joiner.drop();
      await pumpEventQueue();

      final attemptsBefore = joiner.joins.length;
      await keeper.release();
      // A join can sit for the framework's full timeout, so a release can
      // easily land mid-attempt. Putting the phone back on a network the user
      // has already left would be worse than doing nothing.
      await Future<void>.delayed(const Duration(milliseconds: 50));

      expect(joiner.joins, hasLength(attemptsBefore));
      expect(keeper.state, HotspotLinkState.idle);
    });

    test('a drop after release is ignored', () async {
      keeper.adopt(_creds);
      await keeper.release();

      joiner.drop();
      await pumpEventQueue();

      expect(joiner.joins, isEmpty);
    });
  });

  group('as a host', () {
    setUp(() => roles.role = SessionRole.host);

    test('re-hosts on teardown but reports the peer cannot follow', () async {
      keeper.adopt(_creds);

      host.tearDown();
      await pumpEventQueue();

      expect(host.starts, 1);
      // startLocalOnlyHotspot mints a new random SSID and offers no way to ask
      // for the old one, so the peer is looking for a name that is gone.
      expect(keeper.state, HotspotLinkState.lost);
    });

    test('a failed re-host is still reported as lost, not left hanging', () async {
      host.startError = StateError('no channel');
      keeper.adopt(_creds);

      host.tearDown();
      await pumpEventQueue();

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
