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
  const RoomBoundWalkieEntry({super.key, this.ride = false});

  /// True only when a preceding connectivity surface already captured the
  /// user's Start intent and is returning here after link setup.
  final bool ride;

  static Widget buildPage({bool ride = false}) =>
      RoomBoundWalkieEntry(ride: ride);

  @override
  State<RoomBoundWalkieEntry> createState() => _RoomBoundWalkieEntryState();
}

class _RoomBoundWalkieEntryState extends State<RoomBoundWalkieEntry> {
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
  final RoomConnectionReadinessGate _readinessGate =
      const RoomConnectionReadinessGate();
  Future<_EntryState>? _activeStart;
  int _readinessEpoch = 0;

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

  /// Fast local precheck only. This can refuse an impossible attempt but can
  /// never grant live entry; signed Room peer proof below is the authority.
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
      // Deliberately omit link.name: it may contain an SSID or other user
      // network metadata and readiness diagnostics must remain credential-free.
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
      // Only an explicit null selection is allowed to enter legacy quick
      // access. A stale selected Room and a storage read failure are both
      // fail-closed states and must never silently turn into unrelated audio.
      final selectedId = await rooms.selectedRoomId();
      if (selectedId != null) {
        final selected = await SelectedRoomLobbyResolver(rooms).resolve();
        if (selected == null) return const _EntryState.invalidSelection();
        if (widget.ride) {
          _showAttemptingRoom(selected);
          return await _startSelectedRoom(selected);
        }
        return _EntryState.lobby(selected);
      }
    } catch (e) {
      Logger.log('Room selection resolution failed: $e');
      return const _EntryState.recoverable(_EntryFailure.selectionReadFailed);
    }

    // No durable Room selected: retain the legacy quick-access channel. This
    // path makes no claim that a Room is connected and is outside the Room
    // readiness contract.
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

  Future<_EntryState> _startSelectedRoom(SavedRoom room) {
    final existing = _activeStart;
    if (existing != null) return existing;

    final future = _startSelectedRoomOnce(room);
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

  Future<_EntryState> _startSelectedRoomOnce(SavedRoom room) async {
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

    return _verifiedLiveFor(room);
  }

  Future<_EntryState> _verifiedLiveFor(SavedRoom room) async {
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
      Logger.diagnostic('room: readiness stage=peer_proof_missing');
      return _EntryState.lobby(room, failure: _EntryFailure.peerProofMissing);
    }

    // The coordinator owns the epoch *before* any carrier bind or readiness
    // wait.  At cold start remote capability and LAN reachability are unknown;
    // neither is manufactured from a Wi-Fi mode/interface.  The existing
    // deterministic bootstrap side is only an adoption hint until the signed
    // proof/capability runtime can publish verified evidence.
    final bootstrapHost = _bootstrapHotspotHost(room);
    final start = _coordinator.requestStart(
      requester: localMemberId,
      sharedLanUsable: false,
      candidates: const [],
      bootstrapHotspotHost: bootstrapHost,
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
      if (!await _executePlan(start.plan!, room)) {
        _coordinator.cancel(epoch: start.epoch);
        return _EntryState.lobby(
          room,
          failure: _EntryFailure.transportPlanMismatch,
        );
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

      final readiness = await _readinessGate.wait(
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

  /// The existing one-scan/create flow has exactly one deterministic bootstrap
  /// side. This is not Room ownership or a remote capability assertion.
  RoomMemberId? _bootstrapHotspotHost(SavedRoom room) {
    final members = room.room.activeMembers.toList(growable: false)
      ..sort((a, b) {
        final byJoined = a.joinedAt.compareTo(b.joinedAt);
        return byJoined != 0 ? byJoined : a.id.value.compareTo(b.id.value);
      });
    return members.isEmpty ? null : members.first.id;
  }

  Future<bool> _executePlan(RoomTransportPlan plan, SavedRoom room) async {
    switch (plan.kind) {
      case RoomTransportKind.hotspot:
        final role = _transfer?.sessionRole ?? SessionRole.unknown;
        final localIsElected =
            plan.hotspotHost == room.membership.localMemberId;
        // A role is a bootstrap hint, never an election input.  A contradiction
        // is surfaced as recoverable instead of switching carriers silently.
        if (role == SessionRole.host && !localIsElected) return false;
        if (role == SessionRole.joiner && localIsElected) return false;
        if (localIsElected) {
          await PreLiveHotspotBootstrap().prepareHost();
        }
        return true;
      case RoomTransportKind.sharedLan:
        // This path cannot be selected at cold start. It becomes available only
        // during verified failover after authenticated reachability evidence.
        return false;
      case RoomTransportKind.bluetooth:
        // Group Bluetooth is never promoted to a general voice carrier.
        return room.room.confirmedMembers.length == 2;
      case RoomTransportKind.guest:
        return false;
      case null:
        return false;
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
      _EntryFailure.localLinkMissing => s.no_network,
      _EntryFailure.peerProofMissing => s.bt_waiting_for_peer,
      _EntryFailure.staleAttempt => s.link_reconnecting,
      _EntryFailure.transportBindTimeout ||
      _EntryFailure.transportPlanMismatch ||
      _EntryFailure.coordinatorRejected ||
      _EntryFailure.transportSetup ||
      _EntryFailure.compositionUnavailable ||
      _EntryFailure.selectionReadFailed => s.bt_connection_failed,
    };
  }

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
              onConnect: () => _connect(context, room),
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
            message: context.getString.bt_connection_failed,
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
            onConnect: () => _connect(context, room),
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
                context.getString.bt_connection_failed,
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
