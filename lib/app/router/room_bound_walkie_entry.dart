import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:get_it/get_it.dart';
import 'package:go_router/go_router.dart';

import '../../core/l10n/extension.dart';
import '../../core/motion/app_motion.dart';
import '../../core/router/route_exit.dart';
import '../../core/router/routes.dart';
import '../../core/utils/logger.dart';
import '../../feature/room/api/room_api.dart';
import '../../feature/room/presentation/widget/carrier_status_scope.dart';
import '../../feature/transfer/api/transfer_api.dart';
import '../../feature/walkie/api/walkie_api.dart';

/// Composition-root bridge between a durable selected Room and the live
/// Walkie surface.
///
/// Merely opening the lobby starts no transport or microphone. A selected Room
/// reaches the live surface only after the current attachment is healthy and a
/// remote durable Room member has answered a signed route challenge on that
/// same attachment generation.
class RoomBoundWalkieEntry extends StatefulWidget {
  const RoomBoundWalkieEntry({
    super.key,
    this.ride = false,
    this.start = false,
  });

  /// Arrived from a screen whose job was establishing a link — the hotspot
  /// bridge, Bluetooth pairing, the guest link. That link is what Start uses.
  final bool ride;

  /// Arrived straight from scanning an invite. Connecting starts at once, over
  /// the proximity hand-off the scan opened: scanning was that person's whole
  /// part, and a second "start?" would have two people coordinating a tap.
  final bool start;

  static Widget buildPage({bool ride = false, bool start = false}) =>
      RoomBoundWalkieEntry(ride: ride, start: start);

  @override
  State<RoomBoundWalkieEntry> createState() => _RoomBoundWalkieEntryState();
}

class _RoomBoundWalkieEntryState extends State<RoomBoundWalkieEntry> {
  /// How long the two ends of a proximity hand-off wait for each other. It has
  /// to cover the host bringing an access point up and the joiner finding and
  /// answering Android's "connect to this network?" prompt.
  static const _handoffTimeout = Duration(seconds: 60);

  /// A link that is already up either reaches the others promptly or not at
  /// all; nothing is being set up while this runs.
  static const _existingLinkTimeout = Duration(seconds: 30);

  RoomRepository? _rooms;
  TransferRepository? _transfer;
  SelectedRoomLiveSessionBinding? _binding;
  late Future<_EntryState> _entry;
  SavedRoom? _attemptRoom;
  LiveLinkProbe? _probe;
  TransferModeStore? _modeStore;
  LiveLinkSnapshot? _links;
  StreamSubscription<void>? _linkChanges;
  final RoomConnectionCoordinator _coordinator = RoomConnectionCoordinator();
  Future<_EntryState>? _activeStart;
  int _readinessEpoch = 0;

  SessionRoleStore? get _roleStore =>
      GetIt.instance.isRegistered<SessionRoleStore>()
      ? GetIt.instance<SessionRoleStore>()
      : null;

  @override
  void initState() {
    super.initState();
    _entry = _resolveInitialEntry();
  }

  bool _compose() {
    _composeLinkProbe();
    if (_binding != null) return true;
    try {
      final rooms = GetIt.instance<RoomRepository>();
      final transfer = GetIt.instance<TransferRepository>();
      _binding = SelectedRoomLiveSessionBinding(
        rooms: rooms,
        transfer: transfer,
        modeStore: GetIt.instance<TransferModeStore>(),
        hotspotHost: GetIt.instance<HotspotHost>(),
        hotspotLinkKeeper: GetIt.instance<HotspotLinkKeeper>(),
      );
      _rooms = rooms;
      _transfer = transfer;
      return true;
    } catch (e) {
      Logger.diagnostic('room: readiness stage=binding_unavailable');
      Logger.log('Room-bound walkie entry could not compose: $e');
      return false;
    }
  }

  void _composeLinkProbe() {
    if (_probe != null) return;
    try {
      _probe = GetIt.instance<LiveLinkProbe>();
      _modeStore = GetIt.instance<TransferModeStore>();
    } catch (e) {
      Logger.log('Live link probe unavailable: $e');
      return;
    }
    unawaited(_refreshLinks());
    _linkChanges = _probe?.changes.listen(
      (_) => unawaited(_refreshLinks()),
      onError: (Object _) {},
    );
  }

  Future<LiveLinkSnapshot> _readLinks() async {
    final probe = _probe;
    if (probe == null) return LiveLinkSnapshot.none;
    try {
      return await probe.read();
    } catch (e) {
      Logger.log('Live link read failed: $e');
      return LiveLinkSnapshot.none;
    }
  }

  Future<void> _refreshLinks() async {
    final links = await _readLinks();
    if (!mounted) return;
    setState(() => _links = links);
  }

  LiveLink? get _resolvedLink {
    final links = _links;
    final modeStore = _modeStore;
    if (links == null || modeStore == null) return null;
    return links.resolve(modeStore.mode);
  }

  Future<bool> _openLinkGate() async {
    final probe = _probe;
    final modeStore = _modeStore;
    if (probe == null || modeStore == null) return true;
    final links = await _readLinks();
    if (mounted) setState(() => _links = links);
    final link = links.resolve(modeStore.mode);
    if (!link.isUp) {
      Logger.diagnostic('room: readiness stage=local_link_missing');
      return false;
    }
    final mode = link.modeFor(modeStore.mode);
    if (mode != modeStore.mode) {
      Logger.diagnostic(
        'room: readiness transport_mode=${modeStore.mode.key}->${mode.key}',
      );
      await modeStore.setMode(mode);
    }
    return true;
  }

  Future<_EntryState> _resolveInitialEntry() async {
    if (!_compose()) {
      return const _EntryState.recoverable(
        _EntryFailure.compositionUnavailable,
      );
    }
    final rooms = _rooms;
    if (rooms == null) {
      return const _EntryState.recoverable(
        _EntryFailure.compositionUnavailable,
      );
    }
    try {
      final selectedId = await rooms.selectedRoomId();
      if (selectedId != null) {
        final selected = await SelectedRoomLobbyResolver(rooms).resolve();
        if (selected == null) return const _EntryState.invalidSelection();
        if (widget.ride || widget.start) {
          _showAttemptingRoom(selected);
          return await _startSelectedRoom(
            selected,
            linkEstablished: widget.ride,
          );
        }
        return _EntryState.lobby(selected);
      }
    } catch (e) {
      Logger.log('Room selection resolution failed: $e');
      return const _EntryState.recoverable(_EntryFailure.selectionReadFailed);
    }
    try {
      await _binding?.open(sessionId: _newLegacySessionId());
    } catch (e) {
      Logger.log('Legacy live binding failed: $e');
    }
    return const _EntryState.live();
  }

  void _showAttemptingRoom(SavedRoom room) {
    if (!mounted) {
      _attemptRoom = room;
      return;
    }
    setState(() => _attemptRoom = room);
  }

  Future<_EntryState> _startSelectedRoom(
    SavedRoom room, {
    bool linkEstablished = false,
  }) {
    final existing = _activeStart;
    if (existing != null) return existing;
    final future = _startSelectedRoomOnce(room, linkEstablished);
    _activeStart = future;
    unawaited(
      future.then<void>(
        (_) {
          if (identical(_activeStart, future)) _activeStart = null;
        },
        onError: (Object _, StackTrace _) {
          if (identical(_activeStart, future)) _activeStart = null;
        },
      ),
    );
    return future;
  }

  Future<_EntryState> _startSelectedRoomOnce(
    SavedRoom room,
    bool linkEstablished,
  ) async {
    final rooms = _rooms;
    if (rooms == null) {
      return _EntryState.lobby(
        room,
        failure: _EntryFailure.compositionUnavailable,
      );
    }
    try {
      final current = await SelectedRoomLobbyResolver(rooms).resolve();
      if (current == null || current.room.id != room.room.id) {
        return const _EntryState.invalidSelection();
      }
    } catch (e) {
      Logger.log('Room selection revalidation failed: $e');
      return _EntryState.lobby(
        room,
        failure: _EntryFailure.selectionReadFailed,
      );
    }
    // The lobby can have been mounted while an invite sheet was on top of it.
    // Its callback therefore carries the Room snapshot from before the new
    // member was confirmed. The resolver above is the durable truth; using
    // the callback snapshot here made the host see a one-person Room while
    // its own lobby already rendered two people, and it aborted before the
    // hotspot hand-off could begin.
    return _verifiedLiveFor(current, linkEstablished: linkEstablished);
  }

  Future<_EntryState> _verifiedLiveFor(
    SavedRoom room, {
    required bool linkEstablished,
  }) async {
    final binding = _binding;
    if (binding == null) {
      Logger.diagnostic('room: readiness stage=binding_unavailable');
      return _EntryState.lobby(
        room,
        failure: _EntryFailure.compositionUnavailable,
      );
    }
    final localMemberId = room.membership.localMemberId;
    final expectedPeers = room.room.activeMembers
        .map((member) => member.id)
        .where((memberId) => memberId != localMemberId)
        .toSet();
    if (expectedPeers.isEmpty) {
      Logger.diagnostic(
        'room: readiness stage=expected_peer_missing '
        'confirmed=${room.room.confirmedMembers.length}',
      );
      return _EntryState.lobby(room, failure: _EntryFailure.peerProofMissing);
    }
    // Only a proximity hand-off from a QR scan can plan a hotspot: it is the
    // one channel both phones share before any network does, and the phone
    // that showed the code raises the access point. Without one there is
    // nothing to arrange, so the link this phone already holds — joined
    // through recovery, paired over Bluetooth, a shared network — is tried as
    // it is. "Usable" is provisional then: nothing is reported connected until
    // the readiness gate below holds a signed proof from another member.
    final proximity = RoomProximityControlSessionRegistry.instance;
    final hasProximityHandoff = proximity.hasRoom(room.room.id);
    // `ride=true` only says that a navigation route came back from a link
    // screen.  It is not evidence that a remote Room member can be reached on
    // that link.  In particular, a Room proximity hand-off must keep using its
    // authenticated control socket until the new attachment has produced its
    // own signed proof.  Treating the route flag as a shared LAN skipped that
    // hand-off and sent the user into the generic second-QR fallback.
    final issuer = hasProximityHandoff
        ? proximity.isIssuerFor(room.room.id)
        : null;
    final start = _coordinator.requestStart(
      requester: localMemberId,
      // Non-proximity entry preserves the established recovery contract. A
      // Room proximity hand-off has not yet established a LAN: Wi-Fi
      // creation, association and the signed Room proof are still ahead of
      // it, regardless of the `ride` route flag.
      sharedLanUsable: !hasProximityHandoff,
      candidates: const [],
      bootstrapHotspotHost: issuer == null
          ? null
          : _bootstrapHotspotHost(room, localIsIssuer: issuer),
    );
    if (!start.isActive || start.plan == null) {
      Logger.diagnostic('room: readiness stage=no_verified_transport_plan');
      return _EntryState.lobby(
        room,
        failure: _EntryFailure.transportPlanMismatch,
      );
    }
    final readinessEpoch = ++_readinessEpoch;
    try {
      final planFailure = await _executePlan(
        start.plan!,
        room,
        transportEpoch: start.epoch,
      );
      if (planFailure != null) {
        _coordinator.cancel(epoch: start.epoch);
        return _EntryState.lobby(room, failure: planFailure);
      }
      if (!await _openLinkGate()) {
        _coordinator.cancel(epoch: start.epoch);
        return _EntryState.lobby(room, failure: _EntryFailure.localLinkMissing);
      }
      final runtime = await binding.open(
        sessionId: _newRoomSessionId(room, readinessEpoch),
      );
      if (runtime == null || readinessEpoch != _readinessEpoch) {
        Logger.diagnostic('room: readiness stage=stale_open');
        await binding.close();
        return _EntryState.lobby(room, failure: _EntryFailure.staleAttempt);
      }
      final readiness =
          await RoomConnectionReadinessGate(
            timeout: issuer == null ? _existingLinkTimeout : _handoffTimeout,
          ).wait(
            runtime: runtime,
            peerProofs: binding.verifiedPeerProofs,
            initialPeerProofs: binding.verifiedPeerProofSnapshot,
            expectedPeers: expectedPeers,
            epoch: readinessEpoch,
            currentEpoch: () => _readinessEpoch,
          );
      if (!readiness.isReady || readinessEpoch != _readinessEpoch) {
        final stage = readiness.failure?.name ?? 'peerProofMissing';
        Logger.diagnostic('room: readiness epoch=$readinessEpoch stage=$stage');
        await binding.close();
        return _EntryState.lobby(
          room,
          failure: readinessEpoch != _readinessEpoch
              ? _EntryFailure.staleAttempt
              : _entryFailureFor(readiness.failure),
        );
      }
      _coordinator.reportTransportReady(epoch: start.epoch);
      _coordinator.reportPeerProof(epoch: start.epoch);
      if (_coordinator.state.phase != RoomConnectionPhase.connected) {
        Logger.diagnostic(
          'room: readiness epoch=$readinessEpoch stage=coordinator_rejected',
        );
        _coordinator.cancel(epoch: start.epoch);
        await binding.close();
        return _EntryState.lobby(
          room,
          failure: _EntryFailure.coordinatorRejected,
        );
      }
      Logger.diagnostic(
        'room: readiness epoch=$readinessEpoch stage=connected',
      );
      return _EntryState.live(room: room);
    } catch (e) {
      Logger.diagnostic(
        'room: readiness epoch=$readinessEpoch stage=transport_setup',
      );
      Logger.log('Room verified live entry failed: $e');
      final epoch = _coordinator.state.epoch;
      if (_coordinator.state.isActive) _coordinator.cancel(epoch: epoch);
      try {
        await binding.close();
      } catch (_) {}
      return _EntryState.lobby(room, failure: _EntryFailure.transportSetup);
    }
  }

  static _EntryFailure _entryFailureFor(
    RoomConnectionReadinessFailureStage? failure,
  ) => switch (failure) {
    RoomConnectionReadinessFailureStage.transportBindTimeout =>
      _EntryFailure.transportBindTimeout,
    RoomConnectionReadinessFailureStage.peerProofMissing =>
      _EntryFailure.peerProofMissing,
    RoomConnectionReadinessFailureStage.staleEpoch =>
      _EntryFailure.staleAttempt,
    null => _EntryFailure.peerProofMissing,
  };

  /// The member who raises the first hotspot of a proximity hand-off: the
  /// phone that showed the QR. Each end knows which side of the socket it is
  /// on, so the two agree without an election — and unlike "whoever created
  /// the Room", it is always one of the two phones actually standing there.
  RoomMemberId _bootstrapHotspotHost(
    SavedRoom room, {
    required bool localIsIssuer,
  }) {
    final local = room.membership.localMemberId;
    if (localIsIssuer) return local;
    // The joining side only needs to name somebody other than itself; which
    // remote member that is changes nothing it does.
    return room.room.activeMembers
        .map((member) => member.id)
        .firstWhere((id) => id != local);
  }

  /// Carries out [plan], or says why it could not be carried out.
  Future<_EntryFailure?> _executePlan(
    RoomTransportPlan plan,
    SavedRoom room, {
    required int transportEpoch,
  }) async {
    switch (plan.kind) {
      case RoomTransportKind.hotspot:
        final proximity = RoomProximityControlSessionRegistry.instance;
        if (!proximity.hasRoom(room.room.id)) {
          return _EntryFailure.transportPlanMismatch;
        }
        final localIsElected =
            plan.hotspotHost == room.membership.localMemberId;
        Logger.diagnostic(
          'room: handoff side=${localIsElected ? 'host' : 'joiner'}',
        );
        // The plan decides the side now, so it is what the rest of the
        // transport stack hears: the network rebind coordinator clears its
        // process pin for a host and binds for a joiner, and the hotspot
        // bootstrap refuses to raise an AP for anyone not recorded as host. A
        // hint left over from another Room — or none at all after a restart —
        // would otherwise veto the side both phones just agreed on.
        _roleStore?.setRole(
          localIsElected ? SessionRole.host : SessionRole.joiner,
        );
        if (localIsElected) {
          final credentials = await PreLiveHotspotBootstrap().prepareHost();
          if (credentials == null) return _EntryFailure.transportSetup;
          Logger.diagnostic('room_transport: host credentials ready');
          Logger.diagnostic('room_transport: credential publish begin');
          await proximity.publishHotspot(
            roomId: room.room.id,
            transportEpoch: transportEpoch,
            credentials: credentials,
          );
          Logger.diagnostic('room_transport: credential publish complete');
          return null;
        }
        try {
          final credentials = await proximity.waitForHotspot(
            roomId: room.room.id,
            transportEpoch: transportEpoch,
            timeout: _handoffTimeout,
          );
          final joined = await GetIt.instance<HotspotJoiner>().join(
            credentials,
          );
          switch (joined) {
            case HotspotJoinResult.joined:
              await _modeStore?.setMode(TransferMode.hotspot);
              return null;
            case HotspotJoinResult.wifiOff:
              // Android 10+ does not let an app flip Wi-Fi silently.  Ask in
              // context through the platform's Wi-Fi panel; this is an
              // app-scoped system consent, never a diversion to the manual
              // SSID/QR setup flow.
              await GetIt.instance<HotspotJoiner>().enableWifi();
              return _EntryFailure.wifiOff;
            case HotspotJoinResult.locationOff:
              return _EntryFailure.locationOff;
            case HotspotJoinResult.declined:
              return _EntryFailure.transportSetup;
          }
        } on TimeoutException {
          return _EntryFailure.peerProofMissing;
        }
      case RoomTransportKind.sharedLan:
        // Nothing to arrange (see _verifiedLiveFor). The link gate that runs
        // next refuses a phone that is on nothing at all.
        return null;
      case RoomTransportKind.bluetooth:
        return room.room.confirmedMembers.length == 2
            ? null
            : _EntryFailure.transportPlanMismatch;
      case RoomTransportKind.guest:
      case null:
        return _EntryFailure.transportPlanMismatch;
    }
  }

  void _startRide(SavedRoom room) {
    setState(() {
      _attemptRoom = room;
      _entry = _startSelectedRoom(room);
    });
  }

  void _retryInitial() {
    _readinessEpoch++;
    final epoch = _coordinator.state.epoch;
    if (_coordinator.state.isActive) _coordinator.cancel(epoch: epoch);
    unawaited(_binding?.close() ?? Future<void>.value());
    setState(() {
      _attemptRoom = null;
      _entry = _resolveInitialEntry();
    });
  }

  ChannelIntent _bootstrapIntent(SavedRoom room) {
    final role = _transfer?.sessionRole ?? SessionRole.unknown;
    if (role == SessionRole.host) return ChannelIntent.create;
    if (role == SessionRole.joiner) return ChannelIntent.join;
    final members = room.room.activeMembers.toList(growable: false)
      ..sort((a, b) {
        final byJoined = a.joinedAt.compareTo(b.joinedAt);
        return byJoined != 0 ? byJoined : a.id.value.compareTo(b.id.value);
      });
    if (members.isEmpty) return ChannelIntent.join;
    return members.first.id == room.membership.localMemberId
        ? ChannelIntent.create
        : ChannelIntent.join;
  }

  void _connect(BuildContext context, SavedRoom room) {
    final links = _links ?? LiveLinkSnapshot.none;
    final intent = _bootstrapIntent(room);
    if (links.isUp) {
      final route = ConnectRoute.forStrandedRoom(
        intent: intent,
        pinned: _modeStore?.pinnedMode,
      );
      Logger.diagnostic('room: connect stranded intent=${intent.key}');
      context.push(route);
      return;
    }
    final plan = TransportAdvisor.plan(
      intent,
      LinkConditions(
        hasWifi: links.wifi,
        canHostHotspot: Platform.isAndroid,
        canJoinHotspot: Platform.isAndroid || Platform.isIOS,
        bluetoothSupported: Platform.isAndroid || Platform.isIOS,
        pinned: _modeStore?.pinnedMode,
      ),
    );
    Logger.diagnostic(
      'room: connect via ${plan.mode.key} intent=${intent.key}',
    );
    context.push(ConnectRoute.forPlan(plan));
  }

  String _newRoomSessionId(SavedRoom room, int epoch) =>
      'room-${room.room.id.value}-epoch-$epoch';

  String _newLegacySessionId() =>
      'room-live-${DateTime.now().microsecondsSinceEpoch.toRadixString(36)}';

  String? _failureMessage(BuildContext context, _EntryFailure? failure) {
    if (failure == null) return null;
    final s = context.getString;
    return switch (failure) {
      // A newer attempt replaced this one; it has nothing to tell anybody.
      _EntryFailure.staleAttempt => null,
      _EntryFailure.localLinkMissing => s.room_start_not_linked,
      _EntryFailure.peerProofMissing ||
      _EntryFailure.transportBindTimeout => s.room_start_nobody_answered,
      _EntryFailure.wifiOff => s.room_start_wifi_off,
      _EntryFailure.locationOff => s.room_start_location_off,
      _EntryFailure.transportPlanMismatch ||
      _EntryFailure.coordinatorRejected ||
      _EntryFailure.transportSetup ||
      _EntryFailure.compositionUnavailable ||
      _EntryFailure.selectionReadFailed => s.room_start_failed,
    };
  }

  /// Whether a failure is one the automatic path could not get past, where
  /// connecting the phones by hand is the way forward. A switched-off radio
  /// is not: the message already names the switch.
  static bool _offersConnect(_EntryFailure? failure) => switch (failure) {
    _EntryFailure.localLinkMissing ||
    _EntryFailure.peerProofMissing ||
    _EntryFailure.transportBindTimeout ||
    _EntryFailure.transportPlanMismatch ||
    _EntryFailure.coordinatorRejected ||
    _EntryFailure.transportSetup => true,
    _ => false,
  };

  @override
  void dispose() {
    _readinessEpoch++;
    final epoch = _coordinator.state.epoch;
    if (_coordinator.state.isActive) _coordinator.cancel(epoch: epoch);
    unawaited(_linkChanges?.cancel() ?? Future<void>.value());
    unawaited(_binding?.close() ?? Future<void>.value());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AnimatedSwitcher(
    duration: AppMotion.card,
    switchInCurve: AppMotion.easeOut,
    switchOutCurve: AppMotion.leaving,
    child: _resolved(context),
  );

  Widget _resolved(BuildContext context) => FutureBuilder<_EntryState>(
    future: _entry,
    builder: (context, snapshot) {
      if (snapshot.connectionState != ConnectionState.done) {
        final room = _attemptRoom;
        if (room != null) {
          return RouteExitScope(
            onExit: () => leaveRoomEntry(context),
            child: SelectedRoomLobby(
              room: room,
              connectionPhase: RoomConnectionUiPhase.connecting,
              link: _resolvedLink,
              mode: _modeStore?.mode,
              onStartRide: () {},
              onBack: () => leaveRoomEntry(context),
            ),
          );
        }
        return const Scaffold(
          key: ValueKey('walkie-entry-waiting'),
          body: Center(child: _DelayedSpinner()),
        );
      }
      if (snapshot.hasError) {
        Logger.log('Room-bound walkie entry failed: ${snapshot.error}');
        return RouteExitScope(
          onExit: () => leaveRoomEntry(context),
          child: _RecoverableRoomEntry(
            message: context.getString.room_start_failed,
            onRetry: _retryInitial,
            onBack: () => leaveRoomEntry(context),
          ),
        );
      }
      final state = snapshot.data ?? const _EntryState.invalidSelection();
      if (state.live) {
        final livePage = CarrierStatusScope(
          controller: _binding?.carrierPromotion,
          child: WalkieTalkiePage.buildPage(),
        );
        final room = state.room;
        final binding = _binding;
        final runtime = binding?.runtime;
        if (room != null && binding != null && runtime != null) {
          return RoomConnectionStatusScope(
            room: room,
            runtime: runtime,
            peerProofs: binding.verifiedPeerProofs,
            initialPeerProofs: binding.verifiedPeerProofSnapshot,
            child: livePage,
          );
        }
        return livePage;
      }
      final room = state.room;
      if (room != null) {
        return RouteExitScope(
          onExit: () => leaveRoomEntry(context),
          child: SelectedRoomLobby(
            room: room,
            link: _resolvedLink,
            mode: _modeStore?.mode,
            failureMessage: _failureMessage(context, state.failure),
            onRetry: state.failure == null ? null : () => _startRide(room),
            onStartRide: () => _startRide(room),
            // An accepted Room invite already has an authenticated control
            // channel.  Its recovery stays inside that Room hand-off; the
            // generic channel setup has a second QR and must not replace it.
            onConnect:
                _offersConnect(state.failure) &&
                    !RoomProximityControlSessionRegistry.instance.hasRoom(
                      room.room.id,
                    )
                ? () => _connect(context, room)
                : null,
            onBack: () => leaveRoomEntry(context),
          ),
        );
      }
      if (state.failure != null) {
        return RouteExitScope(
          onExit: () => leaveRoomEntry(context),
          child: _RecoverableRoomEntry(
            message:
                _failureMessage(context, state.failure) ??
                context.getString.room_start_failed,
            onRetry: _retryInitial,
            onBack: () => leaveRoomEntry(context),
          ),
        );
      }
      return RouteExitScope(
        onExit: () => leaveRoomEntry(context),
        child: _InvalidRoomSelection(onBack: () => leaveRoomEntry(context)),
      );
    },
  );
}

void leaveRoomEntry(BuildContext context) =>
    exitRouteTo(context, AppRoutes.roomsPath);

class _DelayedSpinner extends StatefulWidget {
  const _DelayedSpinner();

  @override
  State<_DelayedSpinner> createState() => _DelayedSpinnerState();
}

class _DelayedSpinnerState extends State<_DelayedSpinner> {
  static const _delay = Duration(milliseconds: 220);
  Timer? _timer;
  bool _visible = false;

  @override
  void initState() {
    super.initState();
    _timer = Timer(_delay, () {
      if (mounted) setState(() => _visible = true);
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AnimatedSwitcher(
    duration: AppMotion.card,
    switchInCurve: AppMotion.easeOut,
    child: _visible
        ? const CircularProgressIndicator()
        : const SizedBox.shrink(),
  );
}

enum _EntryFailure {
  localLinkMissing,
  transportBindTimeout,
  peerProofMissing,
  staleAttempt,
  transportPlanMismatch,
  coordinatorRejected,
  transportSetup,
  wifiOff,
  locationOff,
  compositionUnavailable,
  selectionReadFailed,
}

class _EntryState {
  const _EntryState._({this.room, this.live = false, this.failure});

  const _EntryState.lobby(SavedRoom room, {_EntryFailure? failure})
    : this._(room: room, failure: failure);

  const _EntryState.recoverable(_EntryFailure failure)
    : this._(failure: failure);

  const _EntryState.live({SavedRoom? room}) : this._(room: room, live: true);

  const _EntryState.invalidSelection() : this._();

  final SavedRoom? room;
  final bool live;
  final _EntryFailure? failure;
}

class _RecoverableRoomEntry extends StatelessWidget {
  const _RecoverableRoomEntry({
    required this.message,
    required this.onRetry,
    required this.onBack,
  });

  final String message;
  final VoidCallback onRetry;
  final VoidCallback onBack;

  @override
  Widget build(BuildContext context) {
    final s = context.getString;
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.sync_problem_rounded, size: 44),
                const SizedBox(height: 12),
                Text(message, textAlign: TextAlign.center),
                const SizedBox(height: 16),
                FilledButton.icon(
                  key: const Key('room-entry-retry'),
                  onPressed: onRetry,
                  icon: const Icon(Icons.refresh_rounded),
                  label: Text(s.retry),
                ),
                const SizedBox(height: 8),
                OutlinedButton(onPressed: onBack, child: Text(s.entry_back)),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _InvalidRoomSelection extends StatelessWidget {
  const _InvalidRoomSelection({required this.onBack});

  final VoidCallback onBack;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.info_outline_rounded, size: 44),
                const SizedBox(height: 12),
                Text(
                  context.getString.entry_room_unavailable,
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 16),
                OutlinedButton(
                  onPressed: onBack,
                  child: Text(context.getString.entry_back),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
