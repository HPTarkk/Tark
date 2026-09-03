import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:tark/feature/room/data/security/room_transport_identity_secure_store.dart';
import 'package:tark/feature/room/domain/entity/room.dart';
import 'package:tark/feature/room/domain/entity/room_carrier.dart';
import 'package:tark/feature/room/domain/service/room_carrier_promotion_controller.dart';
import 'package:tark/feature/room/domain/service/room_member_transport_identity.dart';
import 'package:tark/feature/room/domain/service/room_transport_planner.dart';
import 'package:tark/feature/transfer/domain/entity/carrier_handover_observation.dart';
import 'package:tark/feature/transfer/domain/entity/hotspot_credentials.dart';
import 'package:tark/feature/transfer/domain/entity/transfer_mode.dart';
import 'package:tark/feature/transfer/domain/repository/carrier_handover_exchange.dart';
import 'package:tark/feature/transfer/domain/service/hotspot_control.dart';
import 'package:tark/feature/transfer/domain/service/transfer_mode_store.dart';
import 'package:tark/feature/transfer/domain/service/hotspot_link_keeper.dart';

/// Everything here is the ride-away scenario: two phones set up on the house
/// Wi-Fi and then leave. The old code only reacted once that Wi-Fi had already
/// gone, at which point there was no path left to agree on a replacement — so
/// these tests are all about the move happening *while the borrowed link still
/// works*.
void main() {
  final roomId = RoomId('a' * 32);
  final hostMember = RoomMemberId('b' * 24);
  final followerMember = RoomMemberId('c' * 24);
  final crypto = RoomMemberTransportIdentityCrypto();

  late RoomMemberTransportKeyPair issuer;
  late RoomTransportIdentityMaterial hostIdentity;
  late RoomTransportIdentityMaterial followerIdentity;

  setUp(() async {
    issuer = await crypto.generateKeyPair();
    hostIdentity = await material(crypto, issuer, roomId, hostMember);
    followerIdentity = await material(crypto, issuer, roomId, followerMember);
  });

  RoomTransportCandidate candidate(
    RoomMemberId id, {
    bool canHostHotspot = true,
    int batteryPercent = 80,
  }) => RoomTransportCandidate(
    memberId: id,
    canHostHotspot: canHostHotspot,
    bluetoothSupported: true,
    backgroundReady: true,
    batteryPercent: batteryPercent,
  );

  RoomCarrierPromotionController build({
    required RoomMemberId localMemberId,
    required RoomTransportIdentityMaterial? identity,
    required _FakeModeStore modeStore,
    required _FakeHotspotHost hotspotHost,
    required _FakeLinkKeeper keeper,
    required _FakeHandoverExchange exchange,
    required List<RoomTransportCandidate> Function() candidates,
    DateTime Function()? clock,
  }) => RoomCarrierPromotionController(
    localMemberId: localMemberId,
    roomId: roomId,
    issuerPublicKey: issuer.publicKey,
    modeStore: modeStore,
    hotspotHost: hotspotHost,
    hotspotLinkKeeper: keeper,
    handoverExchange: exchange,
    candidates: candidates,
    identity: identity,
    crypto: crypto,
    clock: clock,
  );

  group('the host side', () {
    test('raises an access point and announces it over the old link', () async {
      final modeStore = _FakeModeStore(TransferMode.wifi);
      final host = _FakeHotspotHost();
      final keeper = _FakeLinkKeeper();
      final exchange = _FakeHandoverExchange();
      var now = DateTime.utc(2026, 9, 1, 20, 0);

      final controller = build(
        localMemberId: hostMember,
        identity: hostIdentity,
        modeStore: modeStore,
        hotspotHost: host,
        keeper: keeper,
        exchange: exchange,
        // This phone has the fuller battery, so the shared election picks it.
        candidates: () => [
          candidate(hostMember, batteryPercent: 95),
          candidate(followerMember, batteryPercent: 30),
        ],
        clock: () => now,
      );
      addTearDown(controller.dispose);

      controller.start();
      // Nothing yet: the carrier has not been up long enough to be worth
      // leaving, which is what stops this fighting the session's own start-up.
      expect(host.starts, 0);
      expect(controller.status.stage, RoomCarrierStage.settled);

      // evaluate(), not onCarrierChanged(): the carrier has not changed, it
      // has simply been up long enough to be worth leaving. onCarrierChanged
      // would restart the settle window, which is what it is for.
      now = now.add(const Duration(seconds: 30));
      controller.evaluate();
      await pumpEventQueue();

      expect(host.starts, 1);
      expect(modeStore.mode, TransferMode.hotspot);
      expect(keeper.adopted?.ssid, 'Tark-Ride');
      // "moving" is real but momentary: switching this phone's own mode is
      // what completes the move, and the controller sees that immediately.
      // What has to survive is who ended up carrying the Room.
      expect(controller.status.stage, RoomCarrierStage.settled);
      expect(controller.status.durability, RoomCarrierDurability.owned);
      expect(controller.status.localIsHost, isTrue);

      // The announcement is what the peers will actually read off the wire.
      final announced = exchange.provider?.call();
      expect(announced, isNotNull);
      final decoded = RoomCarrierHandover.decode(announced!);
      expect(decoded.hostMemberId, hostMember);
      expect(decoded.ssid, 'Tark-Ride');
      expect(decoded.passphrase, 'ride-secret');
      expect(decoded.generation, 1);
    });

    test(
      'a phone that cannot sign stays put rather than moving blind',
      () async {
        final modeStore = _FakeModeStore(TransferMode.wifi);
        final host = _FakeHotspotHost();
        final exchange = _FakeHandoverExchange();
        var now = DateTime.utc(2026, 9, 1, 20, 0);

        final controller = build(
          localMemberId: hostMember,
          identity: null,
          modeStore: modeStore,
          hotspotHost: host,
          keeper: _FakeLinkKeeper(),
          exchange: exchange,
          candidates: () => [
            candidate(hostMember, batteryPercent: 95),
            candidate(followerMember, batteryPercent: 30),
          ],
          clock: () => now,
        );
        addTearDown(controller.dispose);

        controller.start();
        now = now.add(const Duration(seconds: 30));
        controller.evaluate();
        await pumpEventQueue();

        // Better to keep a working borrowed network than to move a group onto
        // something they have no way to verify.
        expect(host.starts, 0);
        expect(modeStore.mode, TransferMode.wifi);
        expect(exchange.provider?.call(), isNull);
      },
    );

    test(
      'a hotspot that will not start leaves the Room where it was',
      () async {
        final modeStore = _FakeModeStore(TransferMode.wifi);
        final host = _FakeHotspotHost(failing: true);
        var now = DateTime.utc(2026, 9, 1, 20, 0);

        final controller = build(
          localMemberId: hostMember,
          identity: hostIdentity,
          modeStore: modeStore,
          hotspotHost: host,
          keeper: _FakeLinkKeeper(),
          exchange: _FakeHandoverExchange(),
          candidates: () => [
            candidate(hostMember, batteryPercent: 95),
            candidate(followerMember, batteryPercent: 30),
          ],
          clock: () => now,
        );
        addTearDown(controller.dispose);

        controller.start();
        now = now.add(const Duration(seconds: 30));
        controller.evaluate();
        await pumpEventQueue();

        expect(modeStore.mode, TransferMode.wifi);
        expect(controller.status.stage, RoomCarrierStage.settled);
      },
    );

    test('an owned carrier is never promoted away from', () async {
      final modeStore = _FakeModeStore(TransferMode.hotspot);
      final host = _FakeHotspotHost();
      var now = DateTime.utc(2026, 9, 1, 20, 0);

      final controller = build(
        localMemberId: hostMember,
        identity: hostIdentity,
        modeStore: modeStore,
        hotspotHost: host,
        keeper: _FakeLinkKeeper(),
        exchange: _FakeHandoverExchange(),
        candidates: () => [
          candidate(hostMember, batteryPercent: 95),
          candidate(followerMember),
        ],
        clock: () => now,
      );
      addTearDown(controller.dispose);

      controller.start();
      now = now.add(const Duration(minutes: 5));
      controller.evaluate();
      await pumpEventQueue();

      expect(host.starts, 0);
      expect(controller.status.durability, RoomCarrierDurability.owned);
    });
  });

  group('the following side', () {
    late _FakeModeStore modeStore;
    late _FakeLinkKeeper keeper;
    late _FakeHandoverExchange exchange;
    late RoomCarrierPromotionController controller;
    var now = DateTime.utc(2026, 9, 1, 20, 0);

    setUp(() {
      now = DateTime.utc(2026, 9, 1, 20, 0);
      modeStore = _FakeModeStore(TransferMode.wifi);
      keeper = _FakeLinkKeeper();
      exchange = _FakeHandoverExchange();
      controller = build(
        localMemberId: followerMember,
        identity: followerIdentity,
        modeStore: modeStore,
        hotspotHost: _FakeHotspotHost(),
        keeper: keeper,
        exchange: exchange,
        // Only the host can host, so this phone never elects itself.
        candidates: () => [
          candidate(hostMember),
          candidate(followerMember, canHostHotspot: false),
        ],
        clock: () => now,
      );
      addTearDown(controller.dispose);
      controller.start();
    });

    Future<String> announcement({
      int generation = 1,
      String ssid = 'Tark-Ride',
      String passphrase = 'ride-secret',
      DateTime? issuedAt,
      RoomTransportIdentityMaterial? signer,
    }) async {
      final material = signer ?? hostIdentity;
      final at = issuedAt ?? now;
      return RoomCarrierHandover(
        certificate: material.certificate,
        generation: generation,
        ssid: ssid,
        passphrase: passphrase,
        issuedAt: at,
        hostSignature: await crypto.signCarrierHandover(
          certificate: material.certificate,
          member: material.memberKeyPair,
          generation: generation,
          ssid: ssid,
          passphrase: passphrase,
          issuedAt: at,
        ),
      ).encode();
    }

    test('follows a signed announcement onto the new network', () async {
      // The whole point: this phone moves without a rescan, without the user
      // touching anything, and while the old link still works.
      expect(await controller.applyAnnouncement(await announcement()), isTrue);

      expect(modeStore.mode, TransferMode.hotspot);
      expect(keeper.adopted?.ssid, 'Tark-Ride');
      expect(keeper.adopted?.passphrase, 'ride-secret');
      expect(controller.status.durability, RoomCarrierDurability.owned);
      expect(controller.status.hostMemberId, hostMember);
      expect(controller.status.localIsHost, isFalse);
    });

    test('arriving over the wire has the same effect as calling it', () async {
      exchange.emit(
        CarrierHandoverObservation(
          peerKey: '192.168.8.155',
          encodedHandover: await announcement(),
          observedAt: now,
        ),
      );
      await pumpEventQueue();
      expect(modeStore.mode, TransferMode.hotspot);
    });

    test('refuses one signed by a key outside this Room', () async {
      // The attack this exists to stop: somebody on the house Wi-Fi telling
      // the group to move onto an access point they control.
      final outsiderIssuer = await crypto.generateKeyPair();
      final outsider = await material(
        crypto,
        outsiderIssuer,
        roomId,
        hostMember,
      );
      expect(
        await controller.applyAnnouncement(
          await announcement(ssid: 'Evil-AP', signer: outsider),
        ),
        isFalse,
      );
      expect(modeStore.mode, TransferMode.wifi);
      expect(keeper.adopted, isNull);
    });

    test('refuses one whose SSID was swapped after signing', () async {
      final genuine = RoomCarrierHandover.decode(await announcement());
      final tampered = RoomCarrierHandover(
        certificate: genuine.certificate,
        generation: genuine.generation,
        ssid: 'Evil-AP',
        passphrase: genuine.passphrase,
        issuedAt: genuine.issuedAt,
        hostSignature: genuine.hostSignature,
      ).encode();

      expect(await controller.applyAnnouncement(tampered), isFalse);
      expect(modeStore.mode, TransferMode.wifi);
    });

    test(
      'refuses a stale one naming a network that no longer exists',
      () async {
        final old = await announcement(
          issuedAt: now.subtract(
            RoomCarrierHandover.freshness + const Duration(minutes: 1),
          ),
        );
        expect(await controller.applyAnnouncement(old), isFalse);
        expect(modeStore.mode, TransferMode.wifi);
      },
    );

    test('refuses one for a Room this phone is not in', () async {
      final otherRoom = RoomId('f' * 32);
      final stranger = await material(
        crypto,
        issuer,
        otherRoom,
        RoomMemberId('d' * 24),
      );
      expect(
        await controller.applyAnnouncement(
          await announcement(signer: stranger),
        ),
        isFalse,
      );
      expect(modeStore.mode, TransferMode.wifi);
    });

    test('ignores a generation it has already passed', () async {
      // Two simultaneous elections must not ping-pong the group between two
      // access points.
      expect(
        await controller.applyAnnouncement(await announcement(generation: 5)),
        isTrue,
      );
      keeper.adopted = null;

      expect(
        await controller.applyAnnouncement(
          await announcement(generation: 5, ssid: 'Older-AP'),
        ),
        isFalse,
      );
      expect(
        await controller.applyAnnouncement(
          await announcement(generation: 4, ssid: 'Older-AP'),
        ),
        isFalse,
      );
      expect(keeper.adopted, isNull);

      expect(
        await controller.applyAnnouncement(
          await announcement(generation: 6, ssid: 'Newer-AP'),
        ),
        isTrue,
      );
      expect(keeper.adopted?.ssid, 'Newer-AP');
    });

    test('malformed bytes are ignored rather than thrown', () async {
      expect(await controller.applyAnnouncement('nonsense'), isFalse);
      expect(modeStore.mode, TransferMode.wifi);
    });
  });

  test('the move resolves to settled once the carrier is owned', () async {
    // The status the note reads from. Left as "moving" forever, the hub phone
    // would sit under a spinner for the whole ride and never see the one line
    // it actually needs — that it has no internet until the room closes.
    final modeStore = _FakeModeStore(TransferMode.wifi);
    var now = DateTime.utc(2026, 9, 1, 20, 0);
    final controller = build(
      localMemberId: hostMember,
      identity: hostIdentity,
      modeStore: modeStore,
      hotspotHost: _FakeHotspotHost(),
      keeper: _FakeLinkKeeper(),
      exchange: _FakeHandoverExchange(),
      candidates: () => [
        candidate(hostMember, batteryPercent: 95),
        candidate(followerMember, batteryPercent: 30),
      ],
      clock: () => now,
    );
    addTearDown(controller.dispose);

    controller.start();
    now = now.add(const Duration(seconds: 30));
    controller.evaluate();
    await pumpEventQueue();

    // Switching this phone's mode is what completes the move, and the mode
    // subscription reports it — so the resolution happens without waiting for
    // the next tick. A later tick must not undo it either.
    now = now.add(const Duration(seconds: 30));
    controller.evaluate();

    expect(controller.status.stage, RoomCarrierStage.settled);
    expect(controller.status.durability, RoomCarrierDurability.owned);
    // And it still remembers who ended up carrying the Room.
    expect(controller.status.localIsHost, isTrue);
  });

  test(
    'a follower keeps waiting until the announcement actually lands',
    () async {
      // The mirror case: while the carrier is still borrowed, a tick must NOT
      // collapse "waiting for the host" back to settled.
      var now = DateTime.utc(2026, 9, 1, 20, 0);
      final controller = build(
        localMemberId: followerMember,
        identity: followerIdentity,
        modeStore: _FakeModeStore(TransferMode.wifi),
        hotspotHost: _FakeHotspotHost(),
        keeper: _FakeLinkKeeper(),
        exchange: _FakeHandoverExchange(),
        candidates: () => [
          candidate(hostMember, batteryPercent: 95),
          candidate(followerMember, canHostHotspot: false),
        ],
        clock: () => now,
      );
      addTearDown(controller.dispose);

      controller.start();
      now = now.add(const Duration(seconds: 30));
      controller.evaluate();
      expect(controller.status.stage, RoomCarrierStage.awaitingHost);

      now = now.add(const Duration(seconds: 30));
      controller.evaluate();
      expect(controller.status.stage, RoomCarrierStage.awaitingHost);
    },
  );

  test('a carrier raised by failover is still announced to peers', () async {
    // The dead end the field logs ended in: the reactive ladder raised an
    // access point on one phone and left every other phone "waiting for remote
    // hotspot rejoin" with no way to learn the passphrase.
    final exchange = _FakeHandoverExchange();
    final controller = build(
      localMemberId: hostMember,
      identity: hostIdentity,
      modeStore: _FakeModeStore(TransferMode.hotspot),
      hotspotHost: _FakeHotspotHost(),
      keeper: _FakeLinkKeeper(),
      exchange: exchange,
      candidates: () => [candidate(hostMember), candidate(followerMember)],
    );
    addTearDown(controller.dispose);
    controller.start();

    await controller.announceRaisedCarrier(
      const HotspotCredentials(ssid: 'Recovered', passphrase: 'after-drop'),
    );

    final announced = exchange.provider?.call();
    expect(announced, isNotNull);
    final decoded = RoomCarrierHandover.decode(announced!);
    expect(decoded.ssid, 'Recovered');
    expect(decoded.passphrase, 'after-drop');
    expect(decoded.hostMemberId, hostMember);
    expect(controller.status.localIsHost, isTrue);
  });

  test('a phone with no signing material announces nothing', () async {
    final exchange = _FakeHandoverExchange();
    final controller = build(
      localMemberId: hostMember,
      identity: null,
      modeStore: _FakeModeStore(TransferMode.hotspot),
      hotspotHost: _FakeHotspotHost(),
      keeper: _FakeLinkKeeper(),
      exchange: exchange,
      candidates: () => [candidate(hostMember)],
    );
    addTearDown(controller.dispose);
    controller.start();

    await controller.announceRaisedCarrier(
      const HotspotCredentials(ssid: 'Recovered', passphrase: 'after-drop'),
    );
    expect(exchange.provider?.call(), isNull);
  });

  test(
    'disposing stops announcing so a stale carrier is not advertised',
    () async {
      final exchange = _FakeHandoverExchange();
      final controller = build(
        localMemberId: hostMember,
        identity: hostIdentity,
        modeStore: _FakeModeStore(TransferMode.wifi),
        hotspotHost: _FakeHotspotHost(),
        keeper: _FakeLinkKeeper(),
        exchange: exchange,
        candidates: () => [candidate(hostMember), candidate(followerMember)],
      );
      controller.start();
      expect(exchange.provider, isNotNull);
      await controller.dispose();
      expect(exchange.provider, isNull);
    },
  );
}

Future<RoomTransportIdentityMaterial> material(
  RoomMemberTransportIdentityCrypto crypto,
  RoomMemberTransportKeyPair issuer,
  RoomId roomId,
  RoomMemberId memberId,
) async {
  final member = await crypto.generateKeyPair();
  return RoomTransportIdentityMaterial(
    memberKeyPair: member,
    certificate: await crypto.issueCertificate(
      roomId: roomId,
      memberId: memberId,
      memberPublicKey: member.publicKey,
      issuer: issuer,
    ),
  );
}

class _FakeModeStore implements TransferModeStore {
  _FakeModeStore(this._mode);

  TransferMode _mode;
  final _changes = StreamController<TransferMode>.broadcast(sync: true);

  @override
  TransferMode get mode => _mode;

  @override
  Stream<TransferMode> get modeChanges => _changes.stream;

  @override
  TransferMode? get pinnedMode => null;

  @override
  Stream<TransferMode?> get pinChanges => const Stream<TransferMode?>.empty();

  @override
  Future<void> initialize() async {}

  @override
  Future<void> setMode(TransferMode mode) async {
    _mode = mode;
    _changes.add(mode);
  }

  @override
  Future<void> setPinnedMode(TransferMode? mode) async {}
}

class _FakeHotspotHost implements HotspotHost {
  _FakeHotspotHost({this.failing = false});

  final bool failing;
  int starts = 0;

  @override
  Future<HotspotCredentials> start() async {
    if (failing) throw StateError('tethering_on');
    starts++;
    return const HotspotCredentials(
      ssid: 'Tark-Ride',
      passphrase: 'ride-secret',
    );
  }

  @override
  Future<void> stop() async {}

  @override
  Stream<void> get onStopped => const Stream<void>.empty();

  @override
  Future<void> openFixSettings(String errorCode) async {}

  @override
  Future<HotspotWifiAdvice> wifiAdvice() async => throw UnimplementedError();

  @override
  Future<bool> openWifiPanel() async => false;
}

class _FakeLinkKeeper implements HotspotLinkKeeper {
  HotspotCredentials? adopted;

  @override
  void adopt(HotspotCredentials credentials) => adopted = credentials;

  @override
  HotspotCredentials? get credentials => adopted;

  @override
  Stream<HotspotCredentials> get credentialChanges =>
      const Stream<HotspotCredentials>.empty();

  @override
  Stream<HotspotLinkState> get states => const Stream<HotspotLinkState>.empty();

  @override
  HotspotLinkState get state => HotspotLinkState.idle;

  @override
  Future<void> release() async {}

  @override
  void retryNow() {}

  @override
  Future<void> dispose() async {}
}

class _FakeHandoverExchange implements CarrierHandoverExchange {
  final _observations = StreamController<CarrierHandoverObservation>.broadcast(
    sync: true,
  );
  CarrierHandoverProvider? provider;

  void emit(CarrierHandoverObservation observation) =>
      _observations.add(observation);

  @override
  Stream<CarrierHandoverObservation> get carrierHandoverObservations =>
      _observations.stream;

  @override
  void setCarrierHandoverProvider(CarrierHandoverProvider? value) =>
      provider = value;
}
