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
import 'package:tark/feature/transfer/domain/entity/session_role.dart';
import 'package:tark/feature/transfer/domain/entity/transfer_mode.dart';
import 'package:tark/feature/transfer/domain/repository/carrier_handover_exchange.dart';
import 'package:tark/feature/transfer/domain/service/hotspot_control.dart';
import 'package:tark/feature/transfer/domain/service/hotspot_link_keeper.dart';
import 'package:tark/feature/transfer/domain/service/transfer_mode_store.dart';

/// The move off a home router, run before the channel opens (2026-10-12: two
/// phones on the house Wi-Fi went straight into the channel and stayed there,
/// and the in-channel move never happened).
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
    hostIdentity = await _material(crypto, issuer, roomId, hostMember);
    followerIdentity = await _material(crypto, issuer, roomId, followerMember);
  });

  RoomTransportCandidate candidate(
    RoomMemberId id, {
    bool canHostHotspot = true,
    int batteryPercent = 80,
    bool backgroundReady = true,
  }) => RoomTransportCandidate(
    memberId: id,
    canHostHotspot: canHostHotspot,
    bluetoothSupported: true,
    backgroundReady: backgroundReady,
    batteryPercent: batteryPercent,
  );

  final both = [
    candidate(hostMember, batteryPercent: 95),
    candidate(followerMember, batteryPercent: 30),
  ];

  RoomCarrierPromotionController build({
    required RoomMemberId local,
    required RoomTransportIdentityMaterial? identity,
    required _ModeStore modeStore,
    required _Host host,
    required _Keeper keeper,
    required _Exchange exchange,
    required List<RoomTransportCandidate> Function() candidates,
    Future<HotspotJoinResult> Function(HotspotCredentials)? followHost,
    void Function(SessionRole)? setRole,
  }) => RoomCarrierPromotionController(
    localMemberId: local,
    roomId: roomId,
    issuerPublicKey: issuer.publicKey,
    modeStore: modeStore,
    hotspotHost: host,
    hotspotLinkKeeper: keeper,
    handoverExchange: exchange,
    candidates: candidates,
    identity: identity,
    crypto: crypto,
    followHost: followHost,
    setSessionRole: setRole,
  );

  group('promoteNow', () {
    test('moves at once, without waiting out the settle window', () async {
      final modeStore = _ModeStore(TransferMode.wifi);
      final host = _Host();
      final exchange = _Exchange();
      final roles = <SessionRole>[];
      final controller = build(
        local: hostMember,
        identity: hostIdentity,
        modeStore: modeStore,
        host: host,
        keeper: _Keeper(),
        exchange: exchange,
        candidates: () => both,
        setRole: roles.add,
      );
      addTearDown(controller.dispose);
      controller.start();

      expect(await controller.promoteNow(), RoomCarrierPromotionStart.hosting);
      await pumpEventQueue();

      expect(host.starts, 1);
      expect(roles, [SessionRole.host]);
      expect(modeStore.mode, TransferMode.hotspot);
      expect(exchange.provider?.call(), isNotNull);
      // Once the mode says hotspot the host is on a network it owns: the
      // move is finished on this side and the status rests there, still
      // remembering who carries the Room.
      expect(controller.status.stage, RoomCarrierStage.settled);
      expect(controller.status.localIsHost, isTrue);
      expect(controller.status.generation, 1);
    });

    test(
      'moves before the channel even though no keep-alive is up yet',
      () async {
        // 2026-10-15: the keep-alive only starts with the channel, so before it
        // both phones reported "not background ready", nobody could be elected,
        // and both opened the channel over the house Wi-Fi.
        final modeStore = _ModeStore(TransferMode.wifi);
        final host = _Host();
        final controller = build(
          local: hostMember,
          identity: hostIdentity,
          modeStore: modeStore,
          host: host,
          keeper: _Keeper(),
          exchange: _Exchange(),
          candidates: () => [
            candidate(hostMember, batteryPercent: 95, backgroundReady: false),
            candidate(
              followerMember,
              batteryPercent: 30,
              backgroundReady: false,
            ),
          ],
        );
        addTearDown(controller.dispose);
        controller.start();

        expect(
          await controller.promoteNow(),
          RoomCarrierPromotionStart.hosting,
        );
        await pumpEventQueue();
        expect(host.starts, 1);
      },
    );

    test('reuses an access point left up from an earlier invite instead of '
        'calling the router owned', () async {
      final modeStore = _ModeStore(TransferMode.wifi);
      final host = _Host()..hosting = true;
      final keeper = _Keeper()
        ..adopted = const HotspotCredentials(
          ssid: 'Left-Over',
          passphrase: 'still-up',
        )
        ..linkState = HotspotLinkState.up;
      final exchange = _Exchange();
      final controller = build(
        local: hostMember,
        identity: hostIdentity,
        modeStore: modeStore,
        host: host,
        keeper: keeper,
        exchange: exchange,
        candidates: () => both,
      );
      addTearDown(controller.dispose);
      controller.start();

      expect(await controller.promoteNow(), RoomCarrierPromotionStart.hosting);
      await pumpEventQueue();

      expect(host.starts, 0, reason: 'the AP already on the air is used');
      final announced = RoomCarrierHandover.decode(exchange.provider!()!);
      expect(announced.ssid, 'Left-Over');
      expect(modeStore.mode, TransferMode.hotspot);
    });

    test('an elected host that reports no Wi-Fi/hotspot concurrency still '
        'raises before the channel', () async {
      final modeStore = _ModeStore(TransferMode.wifi);
      final host = _Host()
        ..advice = const HotspotWifiAdvice(
          wifiEnabled: true,
          concurrent: false,
          canPanel: true,
        );
      final controller = build(
        local: hostMember,
        identity: hostIdentity,
        modeStore: modeStore,
        host: host,
        keeper: _Keeper(),
        exchange: _Exchange(),
        candidates: () => both,
      );
      addTearDown(controller.dispose);
      controller.start();

      expect(await controller.promoteNow(), RoomCarrierPromotionStart.hosting);
      await pumpEventQueue();
      expect(host.starts, 1);
    });

    test('says so when nobody present can host', () async {
      final controller = build(
        local: hostMember,
        identity: hostIdentity,
        modeStore: _ModeStore(TransferMode.wifi),
        host: _Host(),
        keeper: _Keeper(),
        exchange: _Exchange(),
        candidates: () => [
          candidate(hostMember, canHostHotspot: false),
          candidate(followerMember, canHostHotspot: false),
        ],
      );
      addTearDown(controller.dispose);
      controller.start();

      expect(
        await controller.promoteNow(rosterWait: Duration.zero),
        RoomCarrierPromotionStart.noEligibleHost,
      );
    });

    test('waits for the other phone\'s capabilities, then elects', () async {
      var roster = [candidate(followerMember)];
      final controller = build(
        local: followerMember,
        identity: followerIdentity,
        modeStore: _ModeStore(TransferMode.wifi),
        host: _Host(),
        keeper: _Keeper(),
        exchange: _Exchange(),
        candidates: () => roster,
      );
      addTearDown(controller.dispose);
      controller.start();

      final started = controller.promoteNow();
      await Future<void>.delayed(const Duration(milliseconds: 400));
      roster = [
        candidate(hostMember, batteryPercent: 95),
        candidate(followerMember, batteryPercent: 30),
      ];
      expect(await started, RoomCarrierPromotionStart.following);
      expect(controller.status.stage, RoomCarrierStage.awaitingHost);
    });

    test('standDown stops any later automatic attempt', () async {
      final host = _Host();
      final controller = build(
        local: hostMember,
        identity: hostIdentity,
        modeStore: _ModeStore(TransferMode.wifi),
        host: host,
        keeper: _Keeper(),
        exchange: _Exchange(),
        candidates: () => both,
      );
      addTearDown(controller.dispose);
      controller.start();
      controller.standDown();
      controller.evaluate();
      await pumpEventQueue();
      expect(host.starts, 0);
      expect(controller.status.stage, RoomCarrierStage.settled);
    });
  });

  group('the follower', () {
    Future<String> announcement({int generation = 1}) async {
      final at = DateTime.now().toUtc();
      return RoomCarrierHandover(
        certificate: hostIdentity.certificate,
        generation: generation,
        ssid: 'Tark-Ride',
        passphrase: 'ride-secret',
        issuedAt: at,
        hostSignature: await crypto.signCarrierHandover(
          certificate: hostIdentity.certificate,
          member: hostIdentity.memberKeyPair,
          generation: generation,
          ssid: 'Tark-Ride',
          passphrase: 'ride-secret',
          issuedAt: at,
        ),
      ).encode();
    }

    test(
      'actually joins the host\'s network before calling it moved',
      () async {
        final modeStore = _ModeStore(TransferMode.wifi);
        final keeper = _Keeper();
        final joined = <String>[];
        final roles = <SessionRole>[];
        final controller = build(
          local: followerMember,
          identity: followerIdentity,
          modeStore: modeStore,
          host: _Host(),
          keeper: keeper,
          exchange: _Exchange(),
          candidates: () => both,
          followHost: (credentials) async {
            joined.add(credentials.ssid);
            // Still on the router while Android is joining.
            expect(modeStore.mode, TransferMode.wifi);
            return HotspotJoinResult.joined;
          },
          setRole: roles.add,
        );
        addTearDown(controller.dispose);
        controller.start();

        expect(
          await controller.applyAnnouncement(await announcement()),
          isTrue,
        );
        expect(joined, ['Tark-Ride']);
        expect(roles, [SessionRole.joiner]);
        expect(keeper.adopted?.ssid, 'Tark-Ride');
        expect(modeStore.mode, TransferMode.hotspot);
      },
    );

    test('a declined join stays on the router and says why, once', () async {
      final modeStore = _ModeStore(TransferMode.wifi);
      final keeper = _Keeper();
      var joins = 0;
      final controller = build(
        local: followerMember,
        identity: followerIdentity,
        modeStore: modeStore,
        host: _Host(),
        keeper: keeper,
        exchange: _Exchange(),
        candidates: () => both,
        followHost: (_) async {
          joins++;
          return HotspotJoinResult.declined;
        },
      );
      addTearDown(controller.dispose);
      controller.start();

      final encoded = await announcement();
      expect(await controller.applyAnnouncement(encoded), isFalse);
      // The host repeats its announcement on every ping. Android's prompt
      // must not come back up every second.
      expect(await controller.applyAnnouncement(encoded), isFalse);

      expect(joins, 1);
      expect(keeper.adopted, isNull);
      expect(modeStore.mode, TransferMode.wifi);
      expect(controller.status.stage, RoomCarrierStage.settled);
      expect(controller.status.failure, RoomCarrierMoveFailure.joinDeclined);
    });

    test('does not start a second move while the join is under way', () async {
      final joining = Completer<HotspotJoinResult>();
      final host = _Host();
      final controller = build(
        local: followerMember,
        identity: followerIdentity,
        modeStore: _ModeStore(TransferMode.wifi),
        host: host,
        keeper: _Keeper(),
        exchange: _Exchange(),
        // Both could host, and this phone has the fuller battery: a second
        // election mid-join would pick it.
        candidates: () => [
          candidate(hostMember, batteryPercent: 10),
          candidate(followerMember, batteryPercent: 99),
        ],
        followHost: (_) => joining.future,
      );
      addTearDown(controller.dispose);
      controller.start();
      unawaited(controller.promoteNow(rosterWait: Duration.zero));
      await pumpEventQueue();
      // promoteNow elected this phone; reset to a follower as if the other
      // phone's announcement won the race.
      final applied = controller.applyAnnouncement(
        await announcement(generation: 2),
      );
      await pumpEventQueue();
      final startsBefore = host.starts;
      controller.evaluate();
      await pumpEventQueue();
      expect(host.starts, startsBefore);
      joining.complete(HotspotJoinResult.joined);
      await applied;
    });
  });

  test('durability: a leftover AP in channel mode is still owned', () async {
    // Unchanged in the channel: there the recorded mode can lag a hotspot the
    // bridge raised, and moving a pair off their own AP would be the bug.
    final controller = build(
      local: hostMember,
      identity: hostIdentity,
      modeStore: _ModeStore(TransferMode.wifi),
      host: _Host()..hosting = true,
      keeper: _Keeper(),
      exchange: _Exchange(),
      candidates: () => both,
    );
    addTearDown(controller.dispose);
    controller.start();
    await pumpEventQueue();
    expect(controller.status.durability, RoomCarrierDurability.owned);
  });
}

Future<RoomTransportIdentityMaterial> _material(
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

class _ModeStore implements TransferModeStore {
  _ModeStore(this._mode);

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

class _Host implements HotspotHost {
  bool hosting = false;
  int starts = 0;
  HotspotWifiAdvice? advice;

  @override
  bool get isHosting => hosting || starts > 0;

  @override
  Future<HotspotCredentials> start() async {
    starts++;
    return const HotspotCredentials(ssid: 'Tark-Ride', passphrase: 'secret');
  }

  @override
  Future<void> stop() async => hosting = false;

  @override
  Stream<void> get onStopped => const Stream<void>.empty();

  @override
  Future<void> openFixSettings(String errorCode) async {}

  @override
  Future<HotspotWifiAdvice> wifiAdvice() async =>
      advice ??
      const HotspotWifiAdvice(
        wifiEnabled: true,
        concurrent: true,
        canPanel: true,
      );

  @override
  Future<bool> openWifiPanel() async => false;
}

class _Keeper implements HotspotLinkKeeper {
  HotspotCredentials? adopted;
  HotspotLinkState linkState = HotspotLinkState.idle;

  @override
  void adopt(HotspotCredentials credentials) {
    adopted = credentials;
    linkState = HotspotLinkState.up;
  }

  @override
  HotspotCredentials? get credentials => adopted;

  @override
  Stream<HotspotCredentials> get credentialChanges =>
      const Stream<HotspotCredentials>.empty();

  @override
  Stream<HotspotLinkState> get states => const Stream<HotspotLinkState>.empty();

  @override
  HotspotLinkState get state => linkState;

  @override
  Future<void> release() async {}

  @override
  void retryNow() {}

  @override
  Future<void> dispose() async {}
}

class _Exchange implements CarrierHandoverExchange {
  final _observations = StreamController<CarrierHandoverObservation>.broadcast(
    sync: true,
  );
  CarrierHandoverProvider? provider;

  @override
  Stream<CarrierHandoverObservation> get carrierHandoverObservations =>
      _observations.stream;

  @override
  void setCarrierHandoverProvider(CarrierHandoverProvider? value) =>
      provider = value;
}
