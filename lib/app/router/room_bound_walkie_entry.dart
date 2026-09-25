import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:get_it/get_it.dart';
import 'package:go_router/go_router.dart';

import '../../core/identity/channel_membership.dart';
import '../../core/l10n/extension.dart';
import '../../core/motion/app_motion.dart';
import '../../core/router/route_exit.dart';
import '../../core/router/routes.dart';
import '../../core/utils/android_sdk.dart';
import '../../core/utils/logger.dart';
import '../../feature/room/api/room_api.dart';
import '../../feature/room/presentation/widget/carrier_status_scope.dart';
import '../../feature/transfer/api/hotspot_invite_api.dart';
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
    this.guidedReconnect,
    this.wifiCheck,
    this.prepareHost,
  });

  /// Arrived from a screen whose job was establishing a link — the hotspot
  /// bridge, Bluetooth pairing, the guest link. That link is what Start uses.
  final bool ride;

  /// Arrived straight from scanning an invite. Connecting starts at once, over
  /// the proximity hand-off the scan opened: scanning was that person's whole
  /// part, and a second "start?" would have two people coordinating a tap.
  final bool start;

  /// Whether Start without a proximity hand-off opens the guided reconnect
  /// screen. Null follows the platform (Android and iOS); tests set it.
  final bool? guidedReconnect;

  /// Whether the scanning side reads the Wi-Fi radio before opening the
  /// camera. Null follows the platform (Android: iOS cannot read it this way,
  /// and would read "off"); tests set it.
  final bool? wifiCheck;

  /// Brings this phone's hotspot up. Null uses the real bridge; tests set it.
  final Future<HotspotCredentials?> Function()? prepareHost;

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

  /// The pre-live Wi-Fi presence of the attempt in flight, if it has one.
  RoomPreLiveAnnouncer? _announcer;

  /// How long a phone showing its code waits for the other person to walk
  /// over, open the Room and scan it.
  static const _showCodeTimeout = Duration(minutes: 3);

  final RoomHotspotHistory _hotspotHistory = RoomHotspotHistory();

  /// The guided reconnect screen, while one is up. It takes the whole page.
  RoomReconnectModel? _reconnectModel;
  SavedRoom? _reconnectRoom;
  int _reconnectToken = 0;
  Completer<HotspotCredentials?>? _scanWaiter;
  Completer<bool>? _scanResult;

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
    bool useHomeWifi = false,
  }) {
    final existing = _activeStart;
    if (existing != null) return existing;
    final future = _startSelectedRoomOnce(
      room,
      linkEstablished,
      useHomeWifi: useHomeWifi,
    );
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
    bool linkEstablished, {
    bool useHomeWifi = false,
  }) async {
    final rooms = _rooms;
    if (rooms == null) {
      return _EntryState.lobby(
        room,
        failure: _EntryFailure.compositionUnavailable,
      );
    }
    late final SavedRoom current;
    try {
      final resolved = await SelectedRoomLobbyResolver(rooms).resolve();
      if (resolved == null || resolved.room.id != room.room.id) {
        return const _EntryState.invalidSelection();
      }
      current = resolved;
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
    if (useHomeWifi) {
      // Asked for by name. The network is whatever this phone is on, so it is
      // recorded as plain Wi-Fi rather than the phones' own connection.
      Logger.diagnostic('room: start over home Wi-Fi requested');
      await _modeStore?.setMode(TransferMode.wifi);
      return _verifiedLiveFor(current, linkEstablished: true);
    }
    if (!linkEstablished && _guidedReconnectApplies(current)) {
      return _reconnect(current);
    }
    return _verifiedLiveFor(current, linkEstablished: linkEstablished);
  }

  /// Start with no proximity hand-off open: the phones have no link to each
  /// other yet. Rather than trying whatever network this phone happens to be
  /// on (a home router is used only when asked for), both phones open the
  /// guided reconnect screen: one shows a code, the other scans it.
  bool _guidedReconnectApplies(SavedRoom room) {
    final enabled =
        widget.guidedReconnect ?? (Platform.isAndroid || Platform.isIOS);
    if (!enabled) return false;
    if (RoomProximityControlSessionRegistry.instance.hasRoom(room.room.id)) {
      return false;
    }
    // A transport pinned in Advanced settings is the user's call.
    final pinned = _modeStore?.pinnedMode;
    return pinned != TransferMode.bluetooth && pinned != TransferMode.guest;
  }

  // ------------------------------------------------------ guided reconnect

  /// Runs one guided reconnect. [showCode] forces a side (the switch on the
  /// screen, or a retry); otherwise both phones pick the same side from the
  /// Room's hotspot history.
  Future<_EntryState> _reconnect(
    SavedRoom room, {
    bool? showCode,
    String? message,
  }) async {
    final token = ++_reconnectToken;
    final local = room.membership.localMemberId;
    final canHost = await _canHostHotspot() && !Platform.isIOS;
    final RoomMemberId? electedHost = showCode == null
        ? await _electedHost(room)
        : null;
    if (!mounted || token != _reconnectToken) return _EntryState.lobby(room);
    final wantsShow = showCode ?? electedHost == local;
    final show = wantsShow && canHost;
    final peer = _peerFor(room, electedHost: electedHost);
    final peerName = _memberName(peer);
    Logger.diagnostic(
      'room: reconnect side=${show ? 'show' : 'scan'} '
      'elected=${wantsShow ? 'self' : 'peer'} canHost=$canHost',
    );
    final s = context.getString;
    _setReconnect(
      room,
      RoomReconnectModel(
        side: show ? RoomReconnectSide.show : RoomReconnectSide.scan,
        peerName: peerName,
        phase: show ? RoomReconnectPhase.preparing : RoomReconnectPhase.waiting,
        canSwitch: show || canHost,
        message:
            message ??
            (wantsShow && !canHost ? s.reconnect_cannot_host(peerName) : null),
      ),
    );
    return show
        ? _reconnectShowing(room, token)
        : _reconnectScanning(room, token);
  }

  Future<_EntryState> _reconnectShowing(SavedRoom room, int token) async {
    _roleStore?.setRole(SessionRole.host);
    final credentials = await _prepareHost();
    if (!mounted || token != _reconnectToken) return _EntryState.lobby(room);
    final s = context.getString;
    if (credentials == null) {
      _updateReconnect(
        (model) => model.copyWith(
          phase: RoomReconnectPhase.failed,
          message: s.reconnect_host_failed,
        ),
      );
      return _EntryState.lobby(room);
    }
    _updateReconnect(
      (model) => model.copyWith(
        phase: RoomReconnectPhase.waiting,
        qrData: credentials.qrPayload(
          channel: RoomPreLiveAnnouncer.channelFor(room.room.id),
        ),
        clearMessage: true,
      ),
    );
    final outcome = await _verifiedLiveFor(
      room,
      linkEstablished: true,
      readinessTimeout: _showCodeTimeout,
    );
    if (!mounted || token != _reconnectToken) return outcome;
    if (outcome.live) return _leaveReconnect(outcome);
    _updateReconnect(
      (model) => model.copyWith(
        phase: RoomReconnectPhase.failed,
        message:
            _failureMessage(context, outcome.failure) ??
            s.room_start_nobody_answered,
      ),
    );
    return outcome;
  }

  Future<_EntryState> _reconnectScanning(SavedRoom room, int token) async {
    _roleStore?.setRole(SessionRole.joiner);
    // Joining the other phone's connection needs Wi-Fi on. Asked for before
    // the camera opens, not after a scan fails on it.
    if (!await _awaitWifiForScan(token)) return _EntryState.lobby(room);
    while (true) {
      final waiter = Completer<HotspotCredentials?>();
      _scanWaiter = waiter;
      final credentials = await waiter.future;
      if (!mounted || token != _reconnectToken || credentials == null) {
        return _EntryState.lobby(room);
      }
      var joined = await PreLiveHotspotBootstrap().joinHost(credentials);
      if (!mounted || token != _reconnectToken) return _EntryState.lobby(room);
      if (joined == HotspotJoinResult.wifiOff) {
        // Switched off after the camera opened. The code is already in hand,
        // so once Wi-Fi is back this joins with it rather than asking for a
        // second scan.
        _completeScan(false);
        if (!await _awaitWifiForScan(token)) return _EntryState.lobby(room);
        joined = await PreLiveHotspotBootstrap().joinHost(credentials);
        if (!mounted || token != _reconnectToken) {
          return _EntryState.lobby(room);
        }
      }
      final s = context.getString;
      final String? problem = switch (joined) {
        HotspotJoinResult.joined => null,
        HotspotJoinResult.wifiOff => s.reconnect_wifi_off,
        HotspotJoinResult.locationOff => s.reconnect_location_off,
        HotspotJoinResult.declined => s.reconnect_join_failed,
      };
      if (problem == null) {
        await _modeStore?.setMode(TransferMode.hotspot);
        _completeScan(true);
        break;
      }
      _updateReconnect((model) => model.copyWith(message: problem));
      _completeScan(false);
    }
    _updateReconnect(
      (model) => model.copyWith(
        phase: RoomReconnectPhase.connecting,
        clearMessage: true,
      ),
    );
    final outcome = await _verifiedLiveFor(room, linkEstablished: true);
    if (!mounted || token != _reconnectToken) return outcome;
    if (outcome.live) return _leaveReconnect(outcome);
    // Back to the camera with the reason, rather than to a lobby that would
    // only send the person straight back here.
    return _reconnect(
      room,
      showCode: false,
      message: context.getString.reconnect_join_failed,
    );
  }

  /// The longest this phone spends bringing its hotspot up before it says it
  /// could not. Normally a few seconds; Android can also simply never answer,
  /// and that left the phone on a spinner with nothing to press.
  static const _prepareTimeout = Duration(seconds: 60);

  /// Brings this phone's hotspot up, or gives up after [_prepareTimeout].
  Future<HotspotCredentials?> _prepareHost() async {
    final prepare =
        widget.prepareHost ?? () => PreLiveHotspotBootstrap().prepareHost();
    try {
      return await prepare().timeout(_prepareTimeout);
    } on TimeoutException {
      Logger.diagnostic('room: hotspot prepare timed out');
      // The request may still land later; nothing would be holding it then.
      unawaited(_releaseOwnHotspot());
      return null;
    }
  }

  /// How often the Wi-Fi card looks at the radio while it waits for it.
  static const _wifiPoll = Duration(seconds: 1);

  /// Holds the scan side on the "turn on Wi-Fi" card until the radio is on.
  ///
  /// Returns false when the attempt was abandoned meanwhile (back, switch,
  /// retry). Where the radio cannot be read — iOS, or no hotspot service —
  /// this says nothing and lets the camera open, as before.
  Future<bool> _awaitWifiForScan(int token) async {
    final host = _hotspotHost;
    if (host == null) return true;
    var shown = false;
    while (true) {
      if (!mounted || token != _reconnectToken) return false;
      bool on;
      try {
        on = (await host.wifiAdvice()).wifiEnabled;
      } catch (e) {
        Logger.log('Wi-Fi state read failed: $e');
        on = true;
      }
      if (!mounted || token != _reconnectToken) return false;
      if (on) {
        if (shown) {
          Logger.diagnostic('room: reconnect wifi on');
          _updateReconnect(
            (model) => model.copyWith(wifiOff: false, clearMessage: true),
          );
        }
        return true;
      }
      if (!shown) {
        shown = true;
        Logger.diagnostic('room: reconnect waiting for wifi');
        _updateReconnect((model) => model.copyWith(wifiOff: true));
      }
      await Future<void>.delayed(_wifiPoll);
    }
  }

  HotspotHost? get _hotspotHost =>
      (widget.wifiCheck ?? Platform.isAndroid) &&
          GetIt.instance.isRegistered<HotspotHost>()
      ? GetIt.instance<HotspotHost>()
      : null;

  /// The "Turn on Wi-Fi" button. Android 10+ does not let an app flip the
  /// radio itself; this raises the system's own panel over the app.
  void _turnOnWifi() {
    if (!GetIt.instance.isRegistered<HotspotJoiner>()) return;
    unawaited(GetIt.instance<HotspotJoiner>().enableWifi());
  }

  /// The scanner found a code. Hands usable credentials to the waiting scan
  /// loop and reports whether the join went through.
  Future<bool> _onReconnectScan(String raw) async {
    final waiter = _scanWaiter;
    final model = _reconnectModel;
    if (waiter == null || waiter.isCompleted || model == null) return false;
    final credentials = ScannedCode.parse(raw)?.credentials;
    if (credentials == null) {
      _updateReconnect(
        (current) => current.copyWith(
          message: context.getString.reconnect_not_our_code(model.peerName),
        ),
      );
      return false;
    }
    final result = Completer<bool>();
    _scanResult = result;
    waiter.complete(credentials);
    return result.future;
  }

  void _completeScan(bool joined) {
    final result = _scanResult;
    _scanResult = null;
    if (result != null && !result.isCompleted) result.complete(joined);
  }

  /// Switch sides, or retry on the same side.
  void _restartReconnect({required bool showCode}) {
    final room = _reconnectRoom;
    if (room == null) return;
    _abandonReconnectAttempt();
    final next = _reconnect(room, showCode: showCode);
    setState(() {
      _entry = next;
    });
  }

  /// Back out of the reconnect screen to the Room's lobby.
  void _cancelReconnect() {
    final room = _reconnectRoom;
    _abandonReconnectAttempt();
    unawaited(_releaseOwnHotspot());
    setState(() {
      _reconnectModel = null;
      _reconnectRoom = null;
      if (room != null) _entry = Future.value(_EntryState.lobby(room));
    });
  }

  void _abandonReconnectAttempt() {
    _reconnectToken++;
    _readinessEpoch++;
    _handoffFallback = false;
    _handoffCodeTimer?.cancel();
    // The abandoned attempt may still be unwinding; a later Start must plan
    // afresh rather than be handed its future.
    _activeStart = null;
    _announcer?.stop();
    _announcer = null;
    final epoch = _coordinator.state.epoch;
    if (_coordinator.state.isActive) _coordinator.cancel(epoch: epoch);
    final waiter = _scanWaiter;
    _scanWaiter = null;
    if (waiter != null && !waiter.isCompleted) waiter.complete(null);
    _completeScan(false);
    unawaited(_binding?.close() ?? Future<void>.value());
  }

  /// A code nobody is going to scan should not keep this phone off the
  /// internet.
  Future<void> _releaseOwnHotspot() async {
    if (_roleStore?.role != SessionRole.host) return;
    try {
      if (GetIt.instance.isRegistered<HotspotLinkKeeper>()) {
        await GetIt.instance<HotspotLinkKeeper>().release();
      }
      if (GetIt.instance.isRegistered<HotspotHost>()) {
        await GetIt.instance<HotspotHost>().stop();
      }
    } catch (e) {
      Logger.log('Releasing the reconnect hotspot failed: $e');
    }
  }

  _EntryState _leaveReconnect(_EntryState outcome) {
    if (mounted) {
      setState(() {
        _reconnectModel = null;
        _reconnectRoom = null;
      });
    }
    return outcome;
  }

  void _setReconnect(SavedRoom room, RoomReconnectModel model) {
    if (!mounted) return;
    setState(() {
      _reconnectRoom = room;
      _reconnectModel = model;
    });
  }

  void _updateReconnect(
    RoomReconnectModel Function(RoomReconnectModel model) update,
  ) {
    final model = _reconnectModel;
    if (!mounted || model == null) return;
    setState(() => _reconnectModel = update(model));
  }

  Future<RoomMemberId?> _electedHost(SavedRoom room) async {
    try {
      return await _hotspotHistory.electHost(room);
    } catch (e) {
      Logger.log('Hotspot history read failed: $e');
      return RoomHotspotHistory.creatorOf(room);
    }
  }

  /// The person this phone is connecting with: the elected host when that is
  /// someone else, otherwise the first other member.
  RoomMember? _peerFor(SavedRoom room, {RoomMemberId? electedHost}) {
    final local = room.membership.localMemberId;
    final others = room.room.confirmedMembers
        .where((member) => member.id != local)
        .toList(growable: false);
    if (others.isEmpty) return null;
    return others.firstWhere(
      (member) => member.id == electedHost,
      orElse: () => others.first,
    );
  }

  String _memberName(RoomMember? member) {
    final s = context.getString;
    if (member == null) return s.people_unnamed;
    return roomMemberDisplayName(
      member,
      fa: Localizations.localeOf(context).languageCode == 'fa',
      unnamed: s.people_unnamed,
    );
  }

  /// Remembers who hosted this Room's hotspot, so the next reconnect elects
  /// the same phone on both ends without either having to ask.
  Future<void> _recordHotspotHost(
    SavedRoom room,
    Set<RoomMemberId> provenPeers,
  ) async {
    if (_modeStore?.mode != TransferMode.hotspot) return;
    final RoomMemberId? host = switch (_roleStore?.role) {
      SessionRole.host => room.membership.localMemberId,
      SessionRole.joiner when provenPeers.length == 1 => provenPeers.single,
      _ => null,
    };
    if (host == null) return;
    try {
      await _hotspotHistory.recordHost(room.room.id, host);
    } catch (e) {
      Logger.log('Hotspot history write failed: $e');
    }
  }

  Future<_EntryState> _verifiedLiveFor(
    SavedRoom room, {
    required bool linkEstablished,
    Duration? readinessTimeout,
  }) async {
    final outcome = await _verifiedLiveAttempt(
      room,
      linkEstablished: linkEstablished,
      readinessTimeout: readinessTimeout,
    );
    // A no-op unless a slow hand-off put the code or camera up meanwhile.
    return _settleHandoffFallback(room, outcome);
  }

  Future<_EntryState> _verifiedLiveAttempt(
    SavedRoom room, {
    required bool linkEstablished,
    Duration? readinessTimeout,
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
    _joinRoomChannel(room);
    RoomPreLiveAnnouncer? announcer;
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
      // Nothing else binds the Wi-Fi socket or says hello before the live
      // screen, and the gate below will not open the live screen until a peer
      // has been heard. See [RoomPreLiveAnnouncer].
      announcer = _startAnnouncer(room);
      final readiness =
          await RoomConnectionReadinessGate(
            timeout:
                readinessTimeout ??
                (issuer == null ? _existingLinkTimeout : _handoffTimeout),
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
        _releaseAnnouncer(
          announcer,
          current: readinessEpoch == _readinessEpoch,
        );
        // Left active, the coordinator handed the next Start this attempt's
        // epoch and plan back unchanged instead of planning a fresh one.
        _coordinator.cancel(epoch: start.epoch);
        // A superseded attempt must not close the binding its replacement
        // has since opened.
        if (readinessEpoch == _readinessEpoch) await binding.close();
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
        _releaseAnnouncer(announcer, current: true);
        _coordinator.cancel(epoch: start.epoch);
        await binding.close();
        return _EntryState.lobby(
          room,
          failure: _EntryFailure.coordinatorRejected,
        );
      }
      announcer?.handOff();
      if (identical(_announcer, announcer)) _announcer = null;
      unawaited(_recordHotspotHost(room, readiness.peerProof));
      Logger.diagnostic(
        'room: readiness epoch=$readinessEpoch stage=connected',
      );
      return _EntryState.live(room: room);
    } catch (e) {
      Logger.diagnostic(
        'room: readiness epoch=$readinessEpoch stage=transport_setup',
      );
      Logger.log('Room verified live entry failed: $e');
      _releaseAnnouncer(announcer, current: readinessEpoch == _readinessEpoch);
      final epoch = _coordinator.state.epoch;
      if (_coordinator.state.isActive) _coordinator.cancel(epoch: epoch);
      if (readinessEpoch == _readinessEpoch) {
        try {
          await binding.close();
        } catch (_) {}
      }
      return _EntryState.lobby(room, failure: _EntryFailure.transportSetup);
    }
  }

  /// Every member of a Room filters Wi-Fi traffic by the same channel code.
  void _joinRoomChannel(SavedRoom room) {
    if (!GetIt.instance.isRegistered<ChannelMembership>()) return;
    final channel = RoomPreLiveAnnouncer.channelFor(room.room.id);
    final membership = GetIt.instance<ChannelMembership>();
    if (membership.current.value == channel.value) return;
    Logger.diagnostic('room: wire channel aligned to Room');
    membership.join(channel);
  }

  RoomPreLiveAnnouncer? _startAnnouncer(SavedRoom room) {
    final mode = _modeStore?.mode;
    if (mode == null || !RoomPreLiveAnnouncer.appliesTo(mode)) return null;
    if (!GetIt.instance.isRegistered<WifiTransferRepository>()) return null;
    _announcer?.stop();
    final announcer = RoomPreLiveAnnouncer(
      transport: GetIt.instance<WifiTransferRepository>(),
      name: _localName(room),
    )..start();
    _announcer = announcer;
    return announcer;
  }

  /// Ends [announcer]'s attempt. Only the current attempt may release the
  /// socket: a superseded one shares it with the attempt that replaced it.
  void _releaseAnnouncer(
    RoomPreLiveAnnouncer? announcer, {
    required bool current,
  }) {
    if (announcer == null) return;
    if (current) {
      announcer.stop();
    } else {
      announcer.handOff();
    }
    if (identical(_announcer, announcer)) _announcer = null;
  }

  static String _localName(SavedRoom room) {
    for (final member in room.room.members) {
      if (member.id != room.membership.localMemberId) continue;
      final name = member.displayName.trim();
      return isHeldSeatPlaceholder(name) ? '' : name;
    }
    return '';
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
        // The side each helper below records in the role store is what the
        // rest of the transport stack hears: the network rebind coordinator clears its
        // process pin for a host and binds for a joiner, and the hotspot
        // bootstrap refuses to raise an AP for anyone not recorded as host. A
        // hint left over from another Room — or none at all after a restart —
        // would otherwise veto the side both phones just agreed on.
        if (localIsElected && !await _canHostHotspot()) {
          // Android 7.x has no LocalOnlyHotspot. Waiting for this phone to
          // raise one left both ends on "connecting" for a full minute; the
          // other phone can host just as well, so hand it the job.
          Logger.diagnostic('room: handoff host unsupported, peer asked');
          await proximity.declineHotspotHost(roomId: room.room.id);
          return _joinHandoffHotspot(room, transportEpoch: transportEpoch);
        }
        if (localIsElected) {
          return _hostHandoffHotspot(room, transportEpoch: transportEpoch);
        }
        return _joinHandoffHotspot(
          room,
          transportEpoch: transportEpoch,
          hostIfDeclined: true,
        );
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

  Future<_EntryFailure?> _hostHandoffHotspot(
    SavedRoom room, {
    required int transportEpoch,
  }) async {
    _roleStore?.setRole(SessionRole.host);
    final credentials = await _prepareHost();
    if (credentials == null) return _EntryFailure.transportSetup;
    Logger.diagnostic('room_transport: host credentials ready');
    Logger.diagnostic('room_transport: credential publish begin');
    await RoomProximityControlSessionRegistry.instance.publishHotspot(
      roomId: room.room.id,
      transportEpoch: transportEpoch,
      credentials: credentials,
    );
    Logger.diagnostic('room_transport: credential publish complete');
    _armHandoffCode(room, credentials);
    return null;
  }

  /// Joins the hotspot the other end of the hand-off raises. With
  /// [hostIfDeclined], a peer that cannot host makes this phone the host.
  Future<_EntryFailure?> _joinHandoffHotspot(
    SavedRoom room, {
    required int transportEpoch,
    bool hostIfDeclined = false,
  }) async {
    _roleStore?.setRole(SessionRole.joiner);
    final token = ++_reconnectToken;
    final epoch = _readinessEpoch;
    // The details normally arrive over Bluetooth within seconds. If they have
    // not by [_handoffCodeAfter], the camera opens too, for the code the
    // other phone will be showing by then — whichever arrives first is used.
    final scanned = Completer<HotspotCredentials>();
    _handoffCodeTimer?.cancel();
    _handoffCodeTimer = Timer(
      _handoffCodeAfter,
      () => unawaited(_offerHandoffScan(room, token, epoch, scanned)),
    );
    try {
      final credentials = await Future.any([
        RoomProximityControlSessionRegistry.instance.waitForHotspot(
          roomId: room.room.id,
          transportEpoch: transportEpoch,
          timeout: _handoffTimeout,
        ),
        scanned.future,
      ]);
      _handoffCodeTimer?.cancel();
      // Through the bridge, like the host: see [PreLiveHotspotBootstrap.joinHost].
      var joined = await PreLiveHotspotBootstrap().joinHost(credentials);
      if (joined == HotspotJoinResult.wifiOff && _hotspotHost != null) {
        // Joining needs Wi-Fi. Ask for it here, on this phone's own screen,
        // then join with the details already in hand.
        _showHandoffScan(room);
        _completeScan(false);
        if (!await _awaitWifiForScan(token)) {
          return _EntryFailure.staleAttempt;
        }
        joined = await PreLiveHotspotBootstrap().joinHost(credentials);
      }
      _completeScan(joined == HotspotJoinResult.joined);
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
    } on RoomHotspotHostDeclined {
      Logger.diagnostic('room: handoff peer cannot host');
      if (!hostIfDeclined || !await _canHostHotspot()) {
        return _EntryFailure.transportSetup;
      }
      return _hostHandoffHotspot(room, transportEpoch: transportEpoch);
    } finally {
      _handoffCodeTimer?.cancel();
    }
  }

  // ------------------------------------------------ slow hand-off fallback

  /// How long a Bluetooth hand-off gets before the code screen comes up as
  /// well. The first-time invite usually connects well inside it, so that
  /// flow looks as it did; a hand-off whose Bluetooth link quietly died
  /// shows a code both phones can use instead of a spinner.
  static const _handoffCodeAfter = Duration(seconds: 8);
  Timer? _handoffCodeTimer;

  /// The reconnect screen currently up was opened by a slow hand-off rather
  /// than by the guided reconnect, so the hand-off's outcome decides it.
  bool _handoffFallback = false;

  /// Hosting side: once the hotspot is up and the details are sent, show
  /// the code if the other phone has not arrived by [_handoffCodeAfter].
  void _armHandoffCode(SavedRoom room, HotspotCredentials credentials) {
    final epoch = _readinessEpoch;
    _handoffCodeTimer?.cancel();
    _handoffCodeTimer = Timer(_handoffCodeAfter, () {
      if (!mounted || epoch != _readinessEpoch || _reconnectModel != null) {
        return;
      }
      Logger.diagnostic('room: handoff slow, showing code');
      _handoffFallback = true;
      _setReconnect(
        room,
        RoomReconnectModel(
          side: RoomReconnectSide.show,
          peerName: _memberName(_peerFor(room)),
          phase: RoomReconnectPhase.waiting,
          qrData: credentials.qrPayload(
            channel: RoomPreLiveAnnouncer.channelFor(room.room.id),
          ),
          canSwitch: false,
        ),
      );
    });
  }

  /// Joining side: the scan screen, for a hand-off that is taking too long.
  void _showHandoffScan(SavedRoom room) {
    if (_reconnectModel != null) return;
    _handoffFallback = true;
    _setReconnect(
      room,
      RoomReconnectModel(
        side: RoomReconnectSide.scan,
        peerName: _memberName(_peerFor(room)),
        phase: RoomReconnectPhase.waiting,
        canSwitch: false,
      ),
    );
  }

  Future<void> _offerHandoffScan(
    SavedRoom room,
    int token,
    int epoch,
    Completer<HotspotCredentials> scanned,
  ) async {
    if (!mounted || token != _reconnectToken || epoch != _readinessEpoch) {
      return;
    }
    Logger.diagnostic('room: handoff slow, offering scan');
    _showHandoffScan(room);
    if (!await _awaitWifiForScan(token)) return;
    while (!scanned.isCompleted) {
      final waiter = Completer<HotspotCredentials?>();
      _scanWaiter = waiter;
      final credentials = await waiter.future;
      if (credentials == null || token != _reconnectToken) return;
      if (!scanned.isCompleted) scanned.complete(credentials);
    }
  }

  /// Resolves a reconnect screen a slow hand-off put up, once the hand-off
  /// itself has finished: gone on success, and on failure the reason in
  /// place of the spinner — never a silent drop back to the lobby.
  Future<_EntryState> _settleHandoffFallback(
    SavedRoom room,
    _EntryState outcome,
  ) async {
    _handoffCodeTimer?.cancel();
    final shown = _handoffFallback;
    _handoffFallback = false;
    final waiter = _scanWaiter;
    if (shown && waiter != null && !waiter.isCompleted) {
      _scanWaiter = null;
      waiter.complete(null);
    }
    final model = _reconnectModel;
    if (!shown || !mounted || model == null) return outcome;
    if (outcome.live) return _leaveReconnect(outcome);
    if (outcome.failure == _EntryFailure.staleAttempt) return outcome;
    final message =
        _failureMessage(context, outcome.failure) ??
        context.getString.room_start_nobody_answered;
    if (model.side == RoomReconnectSide.scan) {
      // Back to a fresh camera with the reason, as the guided scan does.
      return _reconnect(room, showCode: false, message: message);
    }
    _updateReconnect(
      (current) =>
          current.copyWith(phase: RoomReconnectPhase.failed, message: message),
    );
    return outcome;
  }

  /// Whether this phone can raise a LocalOnlyHotspot (Android 8.0+). Only an
  /// Android below that is known not to; anything unreadable is left to try.
  static Future<bool> _canHostHotspot() async {
    if (!Platform.isAndroid) return true;
    try {
      return await AndroidSdk.version() >= 26;
    } catch (_) {
      return true;
    }
  }

  void _startRide(SavedRoom room, {bool useHomeWifi = false}) {
    setState(() {
      _attemptRoom = room;
      _entry = _startSelectedRoom(room, useHomeWifi: useHomeWifi);
    });
  }

  void _retryInitial() {
    _readinessEpoch++;
    _reconnectToken++;
    _reconnectModel = null;
    _reconnectRoom = null;
    _announcer?.stop();
    _announcer = null;
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
    _reconnectToken++;
    _handoffCodeTimer?.cancel();
    final waiter = _scanWaiter;
    if (waiter != null && !waiter.isCompleted) waiter.complete(null);
    // Already handed off when the Room went live; then the live session owns
    // the socket and this is a no-op.
    _announcer?.stop();
    _announcer = null;
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

  Widget _resolved(BuildContext context) {
    final reconnect = _reconnectModel;
    if (reconnect != null) {
      return RoomReconnectView(
        key: const ValueKey('room-reconnect'),
        model: reconnect,
        onScan: _onReconnectScan,
        onSwitch: () => _restartReconnect(
          showCode: reconnect.side == RoomReconnectSide.scan,
        ),
        onRetry: () => _restartReconnect(
          showCode: reconnect.side == RoomReconnectSide.show,
        ),
        onBack: _cancelReconnect,
        onTurnOnWifi: _turnOnWifi,
      );
    }
    return _resolvedEntry(context);
  }

  Widget _resolvedEntry(BuildContext context) => FutureBuilder<_EntryState>(
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
            // Only when this phone is on a Wi-Fi network, and only on request:
            // the phones' own connection is the default.
            onUseHomeWifi:
                _guidedReconnectApplies(room) && _resolvedLink == LiveLink.wifi
                ? () => _startRide(room, useHomeWifi: true)
                : null,
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
