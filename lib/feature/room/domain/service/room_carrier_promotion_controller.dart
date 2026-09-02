import 'dart:async';

import '../../../../core/utils/logger.dart';
import '../../../transfer/domain/entity/carrier_handover_observation.dart';
import '../../../transfer/domain/entity/hotspot_credentials.dart';
import '../../../transfer/domain/entity/transfer_mode.dart';
import '../../../transfer/domain/repository/carrier_handover_exchange.dart';
import '../../../transfer/domain/service/hotspot_control.dart';
import '../../../transfer/domain/service/hotspot_link_keeper.dart';
import '../../../transfer/domain/service/transfer_mode_store.dart';
import '../../data/security/room_transport_identity_secure_store.dart';
import '../entity/room.dart';
import '../entity/room_carrier.dart';
import 'room_carrier_promotion_planner.dart';
import 'room_member_transport_identity.dart';
import 'room_transport_planner.dart';

/// What the Room is doing about its carrier, in words a person could read.
enum RoomCarrierStage {
  /// On a carrier the Room owns, or one it has no better alternative to.
  settled,

  /// Borrowed carrier, promotion decided, this device is raising the access
  /// point the group will leave on.
  raising,

  /// Borrowed carrier, promotion decided, another member is raising it and
  /// this device is waiting for the announcement.
  awaitingHost,

  /// An announcement has arrived (or this device raised the AP) and the group
  /// is moving across.
  moving,
}

/// A live view of the carrier, for the UI to explain without using the word
/// "network".
final class RoomCarrierStatus {
  const RoomCarrierStatus({
    required this.stage,
    required this.durability,
    required this.generation,
    this.hostMemberId,
    this.localIsHost = false,
  });

  final RoomCarrierStage stage;
  final RoomCarrierDurability durability;
  final int generation;
  final RoomMemberId? hostMemberId;
  final bool localIsHost;

  /// Whether the group is currently being moved. The one state worth saying
  /// out loud, because the host's phone is about to leave the internet.
  bool get isHandingOver =>
      stage == RoomCarrierStage.raising ||
      stage == RoomCarrierStage.awaitingHost ||
      stage == RoomCarrierStage.moving;
}

/// The read-only half of the carrier controller, for anything that only wants
/// to *say* something about the carrier.
///
/// Split out so the one widget with an opinion about this can be built and
/// tested without a hotspot radio, a signing key, a transfer repository and a
/// three-second timer behind it. The presentation layer needs two properties;
/// depending on the whole controller to get them would drag all of that into
/// every test that renders the channel.
abstract interface class RoomCarrierStatusSource {
  RoomCarrierStatus get status;

  Stream<RoomCarrierStatus> get statusChanges;
}

/// Moves a Room off a borrowed network *before* the network is gone.
///
/// ## The failure this exists to remove
///
/// Two riders set up at home, on the house Wi-Fi. Everything measures
/// perfectly. They ride away, the house Wi-Fi drops, and the app's only
/// response was the failover ladder — which runs *after* the carrier has
/// already failed. At that moment the elected hotspot host can raise its
/// access point, but there is no longer any path over which to tell the other
/// phones the SSID and passphrase, so they were left "degraded, waiting for
/// remote hotspot rejoin" forever. That is exactly what the field logs showed:
/// one phone alone on Bluetooth, the other alone on Wi-Fi, both transmitting
/// into nothing while the interface claimed everything was fine.
///
/// So this runs the same move in the opposite order. While the borrowed
/// carrier is *still working* — in the driveway, phones a metre apart — it
/// elects a host, has that host raise its access point, and broadcasts the
/// credentials over the link that still works. By the time the borrowed
/// network disappears, nobody is relying on it.
///
/// ## What it deliberately does not do
///
/// It never promotes away from a carrier the Room already owns, never promotes
/// a Room of one, and never promotes when nobody present can host — staying on
/// a borrowed network that works beats moving to no network at all. And it
/// makes exactly one attempt per generation: a controller that retried on
/// every capability heartbeat would restart the handover continuously.
final class RoomCarrierPromotionController
    implements RoomCarrierStatusSource {
  RoomCarrierPromotionController({
    required this.localMemberId,
    required this.roomId,
    required this.issuerPublicKey,
    required this.modeStore,
    required this.hotspotHost,
    required this.hotspotLinkKeeper,
    required this.handoverExchange,
    required this.candidates,
    this.identity,
    RoomMemberTransportIdentityCrypto? crypto,
    DateTime Function()? clock,
  }) : _crypto = crypto ?? RoomMemberTransportIdentityCrypto(),
       _clock = clock ?? DateTime.now;

  final RoomMemberId localMemberId;
  final RoomId roomId;

  /// The Room's issuer key, which every member already holds. An announcement
  /// that does not chain to it is not from this Room.
  final List<int> issuerPublicKey;

  final TransferModeStore modeStore;
  final HotspotHost hotspotHost;
  final HotspotLinkKeeper hotspotLinkKeeper;
  final CarrierHandoverExchange handoverExchange;

  /// The verified peer roster, as durable members with capabilities. Supplied
  /// by the caller because binding a transport peer to a RoomMemberId is the
  /// Room evidence layer's job, not this controller's.
  final List<RoomTransportCandidate> Function() candidates;

  /// This device's own signing material. Null on a device that has none, which
  /// simply means it can never be elected host — it still follows.
  final RoomTransportIdentityMaterial? identity;

  final RoomMemberTransportIdentityCrypto _crypto;
  final DateTime Function() _clock;

  final _statusController = StreamController<RoomCarrierStatus>.broadcast();
  StreamSubscription<CarrierHandoverObservation>? _handoverSubscription;
  StreamSubscription<TransferMode>? _modeSubscription;
  Timer? _tick;
  DateTime? _carrierUpSince;
  int _generation = 0;
  int? _plannedGeneration;
  String? _announcement;
  bool _disposed = false;

  RoomCarrierStatus _status = const RoomCarrierStatus(
    stage: RoomCarrierStage.settled,
    durability: RoomCarrierDurability.owned,
    generation: 0,
  );

  @override
  RoomCarrierStatus get status => _status;

  @override
  Stream<RoomCarrierStatus> get statusChanges => _statusController.stream;

  /// How often the promotion decision is re-examined.
  ///
  /// Slow. Nothing here is urgent — the whole point is that it happens with
  /// time in hand — and a tick that costs a list rebuild has no business
  /// running at animation cadence on the floor device.
  static const _tickInterval = Duration(seconds: 3);

  void start() {
    if (_disposed) return;
    _carrierUpSince = _clock();
    _handoverSubscription = handoverExchange.carrierHandoverObservations.listen(
      _onHandoverObserved,
      onError: (Object _) {},
    );
    // Announced by whoever is elected; until then this returns null on every
    // ping, which costs one null check per control packet.
    handoverExchange.setCarrierHandoverProvider(() => _announcement);
    // The mode can move without this controller asking — the reactive failover
    // ladder changes it, and so does a hotspot the user set up by hand. Either
    // way the settle window has to restart from the carrier we are actually
    // on, or a Room that has just been dropped onto a new link would be
    // considered ready to leave it immediately.
    _modeSubscription = modeStore.modeChanges.listen(
      (_) => onCarrierChanged(),
      onError: (Object _) {},
    );
    _tick = Timer.periodic(_tickInterval, (_) => evaluate());
    evaluate();
  }

  /// Called when the transport mode changes under us, so the settle window is
  /// measured from the carrier we are actually on rather than from session
  /// start.
  ///
  /// Distinct from [evaluate] precisely because it restarts that window: a
  /// carrier that has only just come up has not earned the right to be left
  /// yet, however long the session has been running.
  void onCarrierChanged() {
    if (_disposed) return;
    _carrierUpSince = _clock();
    evaluate();
  }

  RoomCarrierDurability get _durability =>
      RoomCarrierPromotionPlanner.durabilityOf(_kindFor(modeStore.mode));

  static RoomTransportKind? _kindFor(TransferMode mode) => switch (mode) {
    TransferMode.wifi => RoomTransportKind.sharedLan,
    TransferMode.hotspot => RoomTransportKind.hotspot,
    TransferMode.bluetooth => RoomTransportKind.bluetooth,
    TransferMode.guest => RoomTransportKind.guest,
  };

  /// Re-examines the promotion decision without touching the settle window.
  ///
  /// Runs on a slow timer, and is worth calling directly whenever the verified
  /// roster changes — a second phone appearing is exactly the event that turns
  /// "a Room of one, nothing to do" into "time to move".
  void evaluate() {
    if (_disposed) return;
    final durability = _durability;
    final upSince = _carrierUpSince ?? _clock();
    final decision = RoomCarrierPromotionPlanner.decide(
      RoomCarrierPromotionEnvironment(
        durability: durability,
        candidates: candidates(),
        currentGeneration: _generation,
        carrierUpFor: _clock().difference(upSince),
        peersPresent: candidates()
            .where((candidate) => candidate.memberId != localMemberId)
            .length,
        promotionPlannedForGeneration: _plannedGeneration,
      ),
    );

    if (!decision.shouldPromote) {
      // A handover in flight is not reset by a tick that happens to land
      // during it — except once the carrier is actually owned, which is the
      // move having finished. Without that second half the status would stay
      // "moving" for the rest of the session: the mode change to hotspot is
      // exactly what makes the next decision `alreadyOwned`, so the very tick
      // that proves the handover succeeded was the one being ignored.
      if (!_status.isHandingOver || !durability.isBorrowed) {
        _publish(_settled(durability));
      }
      return;
    }

    _plannedGeneration = decision.generation;
    final localIsHost = decision.localIsHost(localMemberId);
    Logger.diagnostic(
      'carrier: borrowed network — promoting to generation '
      '${decision.generation}, host is ${localIsHost ? "this phone" : "a peer"}',
    );
    _publish(
      RoomCarrierStatus(
        stage: localIsHost
            ? RoomCarrierStage.raising
            : RoomCarrierStage.awaitingHost,
        durability: durability,
        generation: decision.generation,
        hostMemberId: decision.host,
        localIsHost: localIsHost,
      ),
    );
    if (localIsHost) unawaited(_raiseAndAnnounce(decision.generation));
  }

  /// The host half: raise the access point, then say so, repeatedly, over the
  /// carrier that still works.
  Future<void> _raiseAndAnnounce(int generation) async {
    final material = identity;
    if (material == null) {
      // Elected but unable to sign. Better to stay put than to move the group
      // somewhere they cannot verify.
      Logger.log('carrier: elected host has no signing identity; staying put');
      _plannedGeneration = null;
      return;
    }
    try {
      final credentials = await hotspotHost.start();
      if (_disposed) return;
      final issuedAt = _clock().toUtc();
      final signature = await _crypto.signCarrierHandover(
        certificate: material.certificate,
        member: material.memberKeyPair,
        generation: generation,
        ssid: credentials.ssid,
        passphrase: credentials.passphrase,
        issuedAt: issuedAt,
      );
      if (_disposed) return;
      final handover = RoomCarrierHandover(
        certificate: material.certificate,
        generation: generation,
        ssid: credentials.ssid,
        passphrase: credentials.passphrase,
        issuedAt: issuedAt,
        hostSignature: signature,
      );
      // Published before this device switches its own mode. The announcement
      // has to travel over the borrowed carrier, and switching first would
      // take this phone off the very network it needs to speak on.
      _announcement = handover.encode();
      _generation = generation;
      _publish(
        RoomCarrierStatus(
          stage: RoomCarrierStage.moving,
          durability: RoomCarrierDurability.owned,
          generation: generation,
          hostMemberId: localMemberId,
          localIsHost: true,
        ),
      );
      Logger.diagnostic(
        'carrier: hosting generation $generation, announcing to peers',
      );
      hotspotLinkKeeper.adopt(credentials);
      await modeStore.setMode(TransferMode.hotspot);
      onCarrierChanged();
    } catch (error) {
      Logger.log('carrier: could not raise the access point: $error');
      // Let the next tick try again — the phone may simply have been busy.
      _plannedGeneration = null;
      if (!_disposed) _publish(_settled(_durability));
    }
  }

  /// Publishes credentials for an access point this device raised outside the
  /// pre-emptive path — specifically, one raised by the reactive failover
  /// ladder after a carrier had already died.
  ///
  /// Worth doing even though the link that failed is gone. The peers that have
  /// to follow may still reach this device by some other leg, or the old one
  /// may flicker back for a second, and an announcement sitting on every ping
  /// costs nothing while it waits. Without it, a peer that did not raise the
  /// access point itself has no way at all to learn its credentials, which is
  /// exactly the "waiting for remote hotspot rejoin" dead end the field logs
  /// ended in.
  Future<void> announceRaisedCarrier(HotspotCredentials credentials) async {
    final material = identity;
    if (_disposed || material == null) return;
    final generation = _generation + 1;
    try {
      final issuedAt = _clock().toUtc();
      final signature = await _crypto.signCarrierHandover(
        certificate: material.certificate,
        member: material.memberKeyPair,
        generation: generation,
        ssid: credentials.ssid,
        passphrase: credentials.passphrase,
        issuedAt: issuedAt,
      );
      if (_disposed) return;
      _announcement = RoomCarrierHandover(
        certificate: material.certificate,
        generation: generation,
        ssid: credentials.ssid,
        passphrase: credentials.passphrase,
        issuedAt: issuedAt,
        hostSignature: signature,
      ).encode();
      _generation = generation;
      _plannedGeneration = generation;
      _publish(
        RoomCarrierStatus(
          stage: RoomCarrierStage.moving,
          durability: RoomCarrierDurability.owned,
          generation: generation,
          hostMemberId: localMemberId,
          localIsHost: true,
        ),
      );
      Logger.diagnostic(
        'carrier: announcing recovered generation $generation to peers',
      );
    } catch (error) {
      Logger.log('carrier: could not announce the recovered carrier: $error');
    }
  }

  /// The follower half: verify what a peer announced, then go there.
  Future<void> _onHandoverObserved(CarrierHandoverObservation observation) =>
      applyAnnouncement(observation.encodedHandover);

  /// Verifies and, if it holds up, follows an announcement.
  ///
  /// Separated from the stream so the whole acceptance rule is reachable in a
  /// test without a socket. Returns whether the Room moved.
  Future<bool> applyAnnouncement(String encoded) async {
    if (_disposed) return false;
    final RoomCarrierHandover handover;
    try {
      handover = RoomCarrierHandover.decode(encoded);
    } on FormatException {
      return false;
    }

    // Cheap structural checks before the signature, which costs a curve
    // operation and would otherwise be a free way to make every phone in
    // earshot burn CPU.
    if (handover.roomId != roomId) return false;
    if (handover.generation <= _generation) return false;
    if (!handover.isFresh(_clock())) return false;
    if (handover.hostMemberId == localMemberId) return false;

    final ok = await _crypto.verifyCarrierHandover(
      certificate: handover.certificate,
      signature: handover.hostSignature,
      expectedRoomId: roomId,
      expectedIssuerPublicKey: issuerPublicKey,
      generation: handover.generation,
      ssid: handover.ssid,
      passphrase: handover.passphrase,
      issuedAt: handover.issuedAt,
    );
    if (!ok || _disposed) {
      if (!ok) {
        Logger.log('carrier: rejected an unsigned or forged handover');
      }
      return false;
    }
    // Re-checked after the await: a newer generation may have landed while the
    // signature was being verified.
    if (handover.generation <= _generation) return false;

    Logger.diagnostic(
      'carrier: following generation ${handover.generation} to the host',
    );
    _generation = handover.generation;
    _plannedGeneration = handover.generation;
    _publish(
      RoomCarrierStatus(
        stage: RoomCarrierStage.moving,
        durability: RoomCarrierDurability.owned,
        generation: handover.generation,
        hostMemberId: handover.hostMemberId,
      ),
    );
    hotspotLinkKeeper.adopt(
      HotspotCredentials(ssid: handover.ssid, passphrase: handover.passphrase),
    );
    await modeStore.setMode(TransferMode.hotspot);
    onCarrierChanged();
    return true;
  }

  /// A settled status that still remembers who ended up carrying the Room.
  ///
  /// The host's phone gives up its internet connection for as long as it is
  /// the access point, and that fact does not stop being true once the move is
  /// finished — it is the one thing about all of this the user genuinely needs
  /// told, so it has to survive into the resting state rather than flashing
  /// past during the handover.
  RoomCarrierStatus _settled(RoomCarrierDurability durability) =>
      RoomCarrierStatus(
        stage: RoomCarrierStage.settled,
        durability: durability,
        generation: _generation,
        hostMemberId: _generation > 0 ? _status.hostMemberId : null,
        localIsHost: _generation > 0 && _status.localIsHost,
      );

  void _publish(RoomCarrierStatus status) {
    _status = status;
    if (!_statusController.isClosed) _statusController.add(status);
  }

  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    _tick?.cancel();
    _tick = null;
    _announcement = null;
    handoverExchange.setCarrierHandoverProvider(null);
    await _handoverSubscription?.cancel();
    await _modeSubscription?.cancel();
    await _statusController.close();
  }
}
