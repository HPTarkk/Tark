import 'dart:async';

import '../../../../core/utils/logger.dart';
import '../entity/room.dart';
import 'room_carrier_promotion_controller.dart';
import 'room_connection_readiness_gate.dart';

/// One visible step of moving two phones off a shared router and onto one
/// phone's own hotspot. Each is its own beat on screen.
enum RoomMigrationStep {
  /// Both phones proved themselves to each other over the router.
  found,

  /// The phones are agreeing which one of them hosts.
  electing,

  /// The host is bringing its hotspot up; the other phone waits for it.
  preparing,

  /// The other phone is joining the host's hotspot.
  moving,

  /// The phones are proving themselves to each other again, this time over
  /// the hotspot.
  verifying,

  /// Done: the hotspot carries the Room.
  established,
}

/// Which side of the move this phone is on, once that is known.
enum RoomMigrationSide { undecided, host, joiner }

final class RoomMigrationProgress {
  const RoomMigrationProgress(
    this.step, {
    this.side = RoomMigrationSide.undecided,
  });

  final RoomMigrationStep step;
  final RoomMigrationSide side;

  @override
  bool operator ==(Object other) =>
      other is RoomMigrationProgress &&
      other.step == step &&
      other.side == side;

  @override
  int get hashCode => Object.hash(step, side);

  @override
  String toString() => 'RoomMigrationProgress(${step.name}, ${side.name})';
}

enum RoomMigrationResult {
  /// The other phone proved itself over the hotspot, repeatedly. Open the
  /// channel.
  moved,

  /// There is nothing better to move to — nobody can host, or the Room is
  /// already on a member's hotspot. Open the channel on the network it has.
  stay,

  /// The move was attempted and did not finish. The people need one guided
  /// step (one phone shows a code, the other scans it).
  needsGuidance,

  /// Superseded: the screen went away or the user started over.
  abandoned,
}

final class RoomMigrationOutcome {
  const RoomMigrationOutcome(
    this.result, {
    this.side = RoomMigrationSide.undecided,
    this.failure,
    this.noHost = false,
  });

  final RoomMigrationResult result;
  final RoomMigrationSide side;

  /// A [RoomMigrationResult.stay] because the election found nobody to host
  /// (or never heard the other phone's side of it), as opposed to the Room
  /// already being on a phone's own network. Worth telling the person: the
  /// router is not going with them.
  final bool noHost;

  /// Why a guided step is needed, when the move itself said.
  final RoomCarrierMoveFailure? failure;

  @override
  String toString() =>
      'RoomMigrationOutcome(${result.name}, ${side.name}, ${failure?.name})';
}

/// Moves two phones that found each other on a borrowed router onto one
/// phone's own hotspot *before* their channel opens, and opens it only once
/// the move is proven.
///
/// ## Why before, and why proven
///
/// Two phones on the house Wi-Fi used to go straight into the channel over the
/// router, and the move to a hotspot — the only network that survives riding
/// away — happened later, mid-call, behind a status bar that came and went
/// while it did. Being able to see each other on the router proves nothing
/// about the network they will actually ride on, so it is not treated as the
/// end of connecting. It is the start of a sequence:
///
///  1. **found** — the router carried a signed hello both ways;
///  2. **electing** — both phones run the same election on the same signed
///     capabilities and pick the same host;
///  3. **preparing** — the host raises (or reuses) its hotspot and announces
///     it, signed, over the router that still works;
///  4. **moving** — the other phone joins it;
///  5. **verifying** — each phone waits for the other to prove itself, by
///     signature, on a route that is not the router's;
///  6. **established** — and only then does the channel open.
///
/// Each phone runs this on its own, from the same inputs, so both reach
/// "established" off the same evidence — the other one answering over the
/// hotspot — within about a second of each other, without a separate
/// "ready?" round trip that could itself be lost.
///
/// A step that does not come is never retried in a loop, because a loop is a
/// flicker: the move ends in one of three explicit outcomes and the caller
/// shows the matching screen.
final class RoomCarrierMigration {
  RoomCarrierMigration({
    required this.mover,
    required this.peer,
    required this.proofs,
    this.previousRoute,
    DateTime Function()? clock,
    this.peerGaveUp,
    this.moveDeadline = const Duration(seconds: 45),
    this.peerSilence = const Duration(seconds: 25),
    this.stableProofs = 3,
    this.stableSpan = const Duration(seconds: 2),
    this.maxProofGap = const Duration(seconds: 4),
  }) : _clock = clock ?? DateTime.now;

  final RoomCarrierMover mover;

  /// The member on the other end — the one whose proofs decide it.
  final RoomMemberId peer;

  /// Verified proofs from the live session. Only the signed route proof can
  /// say the other phone is really on the new network: a join that Android
  /// reports as done, a socket that binds, an address that changed — none of
  /// those is the other phone.
  final Stream<RoomPeerProofEvidence> proofs;

  /// The route [peer] proved itself on over the router, if known.
  final String? previousRoute;

  final DateTime Function() _clock;

  /// Whether the other phone says it has just given up on this move. Read
  /// on every check; only a "yes" that follows a "no" during this run counts,
  /// so a give-up left over from the attempt before cannot end this one.
  final bool Function()? peerGaveUp;

  /// From the decision to a proven link. Generous: Android's "connect to this
  /// network?" prompt waits for a person. The same on both phones, and the
  /// same as [RoomCarrierPromotionController.handoverDeadline], so neither
  /// phone is still trying after the other has said it could not.
  final Duration moveDeadline;

  /// How long either phone tolerates hearing nothing at all from the other,
  /// on any route, once the move is decided. The same on both sides: when
  /// one phone cannot hear the other, the other cannot hear it either, so
  /// both reach this within a heartbeat of each other. It used to be ten
  /// seconds for the phone waiting on the host and thirty for the host, and
  /// the person holding the second phone watched it keep trying long after
  /// the first had given up (2026-10-16).
  final Duration peerSilence;

  /// How many proofs on the new route make the link "stable".
  final int stableProofs;

  /// …spread over at least this long…
  final Duration stableSpan;

  /// …with no gap between two of them longer than this.
  final Duration maxProofGap;

  final _progress = StreamController<RoomMigrationProgress>.broadcast(
    sync: true,
  );
  RoomMigrationProgress _current = const RoomMigrationProgress(
    RoomMigrationStep.found,
  );

  RoomMigrationProgress get progress => _current;
  Stream<RoomMigrationProgress> get progressChanges => _progress.stream;

  bool _running = false;

  /// Runs the move once. [abandoned] ends it early, from outside.
  Future<RoomMigrationOutcome> run({Future<void>? abandoned}) async {
    assert(!_running, 'a migration runs once');
    _running = true;
    final done = Completer<RoomMigrationOutcome>();
    var side = RoomMigrationSide.undecided;
    DateTime? decidedAt;
    DateTime? lastPeerProofAt;
    final onNewRoute = <DateTime>[];
    StreamSubscription<RoomCarrierStatus>? statusSub;
    StreamSubscription<RoomPeerProofEvidence>? proofSub;
    Timer? watchdog;
    // Edge-triggered: the other phone's "gave up" counts only once it has
    // been heard saying otherwise during this run.
    var peerWasTrying = !(peerGaveUp?.call() ?? false);

    void finish(RoomMigrationOutcome outcome) {
      if (done.isCompleted) return;
      watchdog?.cancel();
      unawaited(statusSub?.cancel());
      unawaited(proofSub?.cancel());
      if (outcome.result == RoomMigrationResult.needsGuidance ||
          outcome.result == RoomMigrationResult.stay) {
        // Whatever happens next happens on the network the Room has, or
        // through the guided step: either way, not through another automatic
        // attempt behind an open channel.
        mover.standDown();
      }
      Logger.diagnostic('carrier_move: $outcome');
      done.complete(outcome);
    }

    void show(RoomMigrationStep step) {
      final next = RoomMigrationProgress(step, side: side);
      if (next == _current) return;
      // Never backwards: a status that arrives late must not walk the screen
      // back a step.
      if (step.index < _current.step.index) return;
      _current = next;
      Logger.diagnostic('carrier_move: step=${step.name} side=${side.name}');
      if (!_progress.isClosed) _progress.add(next);
    }

    void onStatus(RoomCarrierStatus status) {
      if (done.isCompleted) return;
      if (status.isHandingOver && side == RoomMigrationSide.undecided) {
        side = status.localIsHost
            ? RoomMigrationSide.host
            : RoomMigrationSide.joiner;
        decidedAt ??= _clock();
      }
      switch (status.stage) {
        case RoomCarrierStage.raising:
        case RoomCarrierStage.awaitingHost:
          show(RoomMigrationStep.preparing);
        case RoomCarrierStage.moving:
          show(RoomMigrationStep.moving);
        case RoomCarrierStage.settled:
          final failure = status.failure;
          if (failure != null && decidedAt != null) {
            finish(
              RoomMigrationOutcome(
                RoomMigrationResult.needsGuidance,
                side: side,
                failure: failure,
              ),
            );
          }
      }
    }

    void onProof(RoomPeerProofEvidence proof) {
      if (done.isCompleted || proof.memberId != peer) return;
      final now = _clock();
      lastPeerProofAt = now;
      if (decidedAt == null) return;
      if (!_isNewRoute(proof.carrierRoute)) return;
      if (onNewRoute.isNotEmpty &&
          now.difference(onNewRoute.last) > maxProofGap) {
        // A link that answered and then went quiet is not stable yet.
        onNewRoute.clear();
      }
      onNewRoute.add(now);
      show(RoomMigrationStep.verifying);
      if (onNewRoute.length >= stableProofs &&
          now.difference(onNewRoute.first) >= stableSpan) {
        show(RoomMigrationStep.established);
        finish(RoomMigrationOutcome(RoomMigrationResult.moved, side: side));
      }
    }

    void check() {
      if (done.isCompleted) return;
      // The other phone saying it could not is the end of it here too, at
      // once: both screens turn to the same "couldn't move" together.
      final gaveUp = peerGaveUp?.call() ?? false;
      if (!gaveUp) {
        peerWasTrying = true;
      } else if (peerWasTrying) {
        Logger.diagnostic(
          'carrier_move: the other phone gave up — so does this one',
        );
        finish(
          RoomMigrationOutcome(
            RoomMigrationResult.needsGuidance,
            side: side,
            failure: RoomCarrierMoveFailure.timedOut,
          ),
        );
        return;
      }
      final decided = decidedAt;
      if (decided == null) return;
      final now = _clock();
      if (now.difference(decided) >= moveDeadline) {
        finish(
          RoomMigrationOutcome(
            RoomMigrationResult.needsGuidance,
            side: side,
            failure: RoomCarrierMoveFailure.timedOut,
          ),
        );
        return;
      }
      final heard = lastPeerProofAt ?? decided;
      final last = heard.isAfter(decided) ? heard : decided;
      if (onNewRoute.isEmpty && now.difference(last) >= peerSilence) {
        finish(
          RoomMigrationOutcome(
            RoomMigrationResult.needsGuidance,
            side: side,
            failure: RoomCarrierMoveFailure.timedOut,
          ),
        );
      }
    }

    unawaited(
      abandoned?.then((_) {
        finish(const RoomMigrationOutcome(RoomMigrationResult.abandoned));
      }),
    );
    proofSub = proofs.listen(onProof, onError: (Object _) {});
    statusSub = mover.statusChanges.listen(onStatus, onError: (Object _) {});
    watchdog = Timer.periodic(
      const Duration(milliseconds: 250),
      (_) => check(),
    );

    show(RoomMigrationStep.found);
    show(RoomMigrationStep.electing);
    final RoomCarrierPromotionStart start;
    try {
      start = await mover.promoteNow();
    } catch (error) {
      Logger.log('carrier_move: election failed: $error');
      finish(const RoomMigrationOutcome(RoomMigrationResult.stay));
      return done.future;
    }
    if (done.isCompleted) return done.future;
    Logger.diagnostic('carrier_move: election=${start.name}');
    switch (start) {
      case RoomCarrierPromotionStart.notNeeded:
        finish(const RoomMigrationOutcome(RoomMigrationResult.stay));
      case RoomCarrierPromotionStart.noEligibleHost:
      case RoomCarrierPromotionStart.noPeers:
        finish(
          const RoomMigrationOutcome(RoomMigrationResult.stay, noHost: true),
        );
      case RoomCarrierPromotionStart.hosting:
      case RoomCarrierPromotionStart.following:
      case RoomCarrierPromotionStart.alreadyMoving:
        if (side == RoomMigrationSide.undecided) {
          side = switch (start) {
            RoomCarrierPromotionStart.hosting => RoomMigrationSide.host,
            RoomCarrierPromotionStart.following => RoomMigrationSide.joiner,
            _ =>
              mover.status.localIsHost
                  ? RoomMigrationSide.host
                  : RoomMigrationSide.joiner,
          };
        }
        decidedAt ??= _clock();
        // The status that announced the decision may have fired before this
        // listener existed — the other phone's announcement can arrive while
        // the election is still waiting for its roster.
        onStatus(mover.status);
    }
    return done.future;
  }

  /// Whether [route] is somewhere other than the router the phones met on.
  ///
  /// Compared by IPv4 /24 where both sides parse: a phone that rejoins the
  /// same router after a blip comes back with the same prefix and must not be
  /// mistaken for one that moved. Anything else is compared as an opaque
  /// string.
  bool _isNewRoute(String? route) {
    if (route == null || route.isEmpty) return false;
    final before = previousRoute;
    if (before == null || before.isEmpty) return true;
    final a = _prefix24(route);
    final b = _prefix24(before);
    if (a != null && b != null) return a != b;
    return route != before;
  }

  static String? _prefix24(String address) {
    final parts = address.split('.');
    if (parts.length != 4) return null;
    for (final part in parts) {
      final value = int.tryParse(part);
      if (value == null || value < 0 || value > 255) return null;
    }
    return parts.take(3).join('.');
  }

  Future<void> dispose() => _progress.close();
}
