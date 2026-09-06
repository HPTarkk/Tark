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
    if (!_compose()) return const _EntryState.invalidSelection();
    final rooms = _rooms;
    try {
      final selected = await SelectedRoomLobbyResolver(rooms!).resolve();
      if (selected != null) {
        if (widget.ride && await _openLinkGate()) {
          return _startSelectedRoom(selected);
        }
        return _EntryState.lobby(selected);
      }
    } catch (e) {
      Logger.log('Room selection resolution failed: $e');
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
        onError: (Object _, StackTrace __) {
          if (identical(_activeStart, future)) _activeStart = null;
        },
      ),
    );
    return future;
  }

  Future<_EntryState> _startSelectedRoomOnce(SavedRoom room) async {
    final rooms = _rooms;
    if (rooms == null) return const _EntryState.invalidSelection();
    try {
      final current = await SelectedRoomLobbyResolver(rooms).resolve();
      if (current == null || current.room.id != room.room.id) {
        return const _EntryState.invalidSelection();
      }
    } catch (_) {
      return const _EntryState.invalidSelection();
    }

    if (!await _openLinkGate()) return _EntryState.lobby(room);
    return _verifiedLiveFor(room);
  }

  Future<_EntryState> _verifiedLiveFor(SavedRoom room) async {
    final binding = _binding;
    if (binding == null) {
      Logger.diagnostic('room: readiness stage=binding_unavailable');
      return _EntryState.lobby(room);
    }

    final localMemberId = room.membership.localMemberId;
    final expectedPeers = room.room.activeMembers
        .map((member) => member.id)
        .where((memberId) => memberId != localMemberId)
        .toSet();
    if (expectedPeers.isEmpty) {
      Logger.diagnostic('room: readiness stage=peer_proof_missing');
      return _EntryState.lobby(room);
    }

    final readinessEpoch = ++_readinessEpoch;
    try {
      final runtime = await binding.open(
        sessionId: _newRoomSessionId(room, readinessEpoch),
      );
      if (runtime == null || readinessEpoch != _readinessEpoch) {
        Logger.diagnostic('room: readiness stage=stale_open');
        await binding.close();
        return _EntryState.lobby(room);
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
        return _EntryState.lobby(room);
      }

      // Only now is shared LAN usable allowed to become true: the signed route
      // proof above demonstrated that another Room member is actually reachable
      // on this attachment. Radio-up or matching network metadata never sets it.
      final start = _coordinator.requestStart(
        requester: localMemberId,
        sharedLanUsable: _modeStore?.mode == TransferMode.wifi,
        candidates: _connectionCandidates(room),
      );
      if (!start.isActive ||
          start.plan == null ||
          !_transportMatchesPlan(start.plan!, room)) {
        Logger.diagnostic(
          'room: readiness epoch=$readinessEpoch stage=transport_plan_mismatch',
        );
        _coordinator.cancel(epoch: start.epoch);
        await binding.close();
        return _EntryState.lobby(room);
      }

      _coordinator.reportTransportReady(epoch: start.epoch);
      _coordinator.reportPeerProof(epoch: start.epoch);
      if (_coordinator.state.phase != RoomConnectionPhase.connected) {
        Logger.diagnostic(
          'room: readiness epoch=$readinessEpoch stage=coordinator_rejected',
        );
        _coordinator.cancel(epoch: start.epoch);
        await binding.close();
        return _EntryState.lobby(room);
      }

      Logger.diagnostic('room: readiness epoch=$readinessEpoch stage=connected');
      return const _EntryState.live();
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
      return _EntryState.lobby(room);
    }
  }

  /// Candidate set used only after the current transport has already produced
  /// signed Room peer proof. It does not claim remote battery/capability data.
  /// The oldest active member is the same deterministic temporary hotspot side
  /// the existing bootstrap flow uses; verified capability election can replace
  /// it later without changing Room ownership.
  List<RoomTransportCandidate> _connectionCandidates(SavedRoom room) {
    final members = room.room.activeMembers.toList(growable: false)
      ..sort((a, b) {
        final byJoined = a.joinedAt.compareTo(b.joinedAt);
        return byJoined != 0 ? byJoined : a.id.value.compareTo(b.id.value);
      });
    if (members.isEmpty) return const [];

    final temporaryHotspotHost = members.first.id;
    final bluetoothOnly = _modeStore?.mode == TransferMode.bluetooth;
    return [
      for (final member in members)
        RoomTransportCandidate(
          memberId: member.id,
          canHostHotspot: !bluetoothOnly && member.id == temporaryHotspotHost,
          bluetoothSupported: true,
          backgroundReady: true,
          batteryPercent: 50,
          prefersHotspotHost: member.id == temporaryHotspotHost,
        ),
    ];
  }

  bool _transportMatchesPlan(RoomTransportPlan plan, SavedRoom room) {
    final mode = _modeStore?.mode;
    switch (mode) {
      case TransferMode.wifi:
        return plan.kind == RoomTransportKind.sharedLan;
      case TransferMode.hotspot:
        if (plan.kind != RoomTransportKind.hotspot) return false;
        final role = _transfer?.sessionRole ?? SessionRole.unknown;
        final localIsElected = plan.hotspotHost == room.membership.localMemberId;
        if (role == SessionRole.host && !localIsElected) return false;
        if (role == SessionRole.joiner && localIsElected) return false;
        return true;
      case TransferMode.bluetooth:
        return plan.kind == RoomTransportKind.bluetooth;
      case TransferMode.guest:
        // Durable local Rooms do not silently reinterpret an explicitly remote
        // guest carrier as verified local group audio.
        return false;
      case null:
        return false;
    }
  }

  void _startRide(SavedRoom room) {
    setState(() {
      _entry = _startSelectedRoom(room);
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
        return const Scaffold(
          key: ValueKey('walkie-entry-waiting'),
          body: Center(child: _DelayedSpinner()),
        );
      }
      if (snapshot.hasError) {
        Logger.log('Room-bound walkie entry failed: ${snapshot.error}');
        return RouteExitScope(
          onExit: () => leaveRoomEntry(context),
          child: _InvalidRoomSelection(onBack: () => leaveRoomEntry(context)),
        );
      }
      final state = snapshot.data ?? const _EntryState.invalidSelection();
      if (state.live) {
        return CarrierStatusScope(
          controller: _binding?.carrierPromotion,
          child: WalkieTalkiePage.buildPage(),
        );
      }
      final room = state.room;
      if (room != null) {
        return RouteExitScope(
          onExit: () => leaveRoomEntry(context),
          child: SelectedRoomLobby(
            room: room,
            link: _resolvedLink,
            mode: _modeStore?.mode,
            onStartRide: () => _startRide(room),
            onConnect: () => _connect(context, room),
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

class _EntryState {
  const _EntryState._({this.room, this.live = false});

  const _EntryState.lobby(SavedRoom room) : this._(room: room);

  const _EntryState.live() : this._(live: true);

  const _EntryState.invalidSelection() : this._();

  final SavedRoom? room;
  final bool live;
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
