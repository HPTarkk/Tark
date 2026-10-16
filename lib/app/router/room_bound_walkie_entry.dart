import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:get_it/get_it.dart';
import 'package:go_router/go_router.dart';

import '../../core/entitlement/license_gate.dart';
import '../../core/entitlement/feature_access_guard.dart';
import '../../core/entitlement/premium_feature.dart';
import '../../core/entitlement/room_access_policy.dart';
import '../../core/entitlement/subscription_gate_page.dart';
import '../../core/identity/channel_membership.dart';
import '../../core/l10n/extension.dart';
import '../../core/motion/app_motion.dart';
import '../../core/motion/scene_turn.dart';
import '../../core/router/route_exit.dart';
import '../../core/router/routes.dart';
import '../../core/theme/app_colors.dart';
import '../../core/widget/connection_journey.dart';
import '../../core/widget/journey_carry_over.dart';
import '../../core/widget/link_preparing_visual.dart';
import '../../core/settings/connection_history.dart';
import '../../core/utils/android_sdk.dart';
import '../../core/utils/logger.dart';
import '../../feature/room/api/room_api.dart';
import '../../feature/room/presentation/widget/carrier_status_scope.dart';
import '../../feature/room/presentation/widget/one_scan_room_invite_sheet.dart';
import '../../feature/room/presentation/widget/room_carrier_migration_view.dart';
import '../../feature/room/presentation/widget/room_group_access_guard.dart';
import '../../feature/transfer/api/hotspot_invite_api.dart';
import '../../feature/transfer/api/transfer_api.dart';
import '../../feature/walkie/api/walkie_api.dart';
import '../../core/widget/state_emblems.dart';

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
    this.rejoin = false,
    this.guidedReconnect,
    this.wifiCheck,
    this.prepareHost,
    this.moveOffRouter,
    this.carryOver,
  });

  /// Arrived from a screen whose job was establishing a link — the hotspot
  /// bridge, Bluetooth pairing, the guest link. That link is what Start uses.
  final bool ride;

  /// Arrived straight from scanning an invite. Connecting starts at once, over
  /// the proximity hand-off the scan opened: scanning was that person's whole
  /// part, and a second "start?" would have two people coordinating a tap.
  final bool start;

  /// Arrived from Landing's "Get back to …?" question: this phone dropped out
  /// of the selected Room's call (a phone call, the app closed) and the user
  /// asked to go back. See [RoomRejoinTicket].
  final bool rejoin;

  /// Whether Start without a proximity hand-off opens the guided reconnect
  /// screen. Null follows the platform (Android and iOS); tests set it.
  final bool? guidedReconnect;

  /// Whether the scanning side reads the Wi-Fi radio before opening the
  /// camera. Null follows the platform (Android: iOS cannot read it this way,
  /// and would read "off"); tests set it.
  final bool? wifiCheck;

  /// Brings this phone's hotspot up. Null uses the real bridge; tests set it.
  final Future<HotspotCredentials?> Function()? prepareHost;

  /// Whether two phones that met on a shared router move onto one phone's
  /// own hotspot before the channel opens. Null follows the platform (Android
  /// and iOS); tests set it.
  final bool? moveOffRouter;

  /// The scene the invite scanner was showing when it opened this entry, so
  /// the journey carries on from the very first frame instead of waiting for
  /// the Room to be read back.
  final JourneyCarryOver? carryOver;

  static Widget buildPage({
    bool ride = false,
    bool start = false,
    bool rejoin = false,
    JourneyCarryOver? carryOver,
  }) => RoomBoundWalkieEntry(
    ride: ride,
    start: start,
    rejoin: rejoin,
    carryOver: carryOver,
  );

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
  bool _askingToStart = false;
  bool _openingBluetooth = false;

  /// The pre-live Wi-Fi presence of the attempt in flight, if it has one.
  RoomPreLiveAnnouncer? _announcer;

  /// Completed when every readiness wait in flight should stop at once —
  /// the user switched sides, a scan arrived, the screen went away. Waits
  /// otherwise only notice they are stale at their next event, and a quiet
  /// listener may not get one for minutes.
  Completer<void> _abandonWaits = Completer<void>();

  void _abandonReadinessWaits() {
    if (!_abandonWaits.isCompleted) _abandonWaits.complete();
    _abandonWaits = Completer<void>();
  }

  /// How long a phone showing its code waits for the other person to walk
  /// over, open the Room and scan it.
  static const _showCodeTimeout = Duration(minutes: 3);

  final RoomHotspotHistory _hotspotHistory = RoomHotspotHistory();
  final RoomRejoinTicketStore _rejoinTickets = RoomRejoinTicketStore();

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
        prefersHotspotHost: _prefersHostingFor,
        followHotspotHost: _followHotspotHost,
        setSessionRole: (role) => _roleStore?.setRole(role),
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

  /// What this phone advertises as "I should host": it can keep Wi-Fi up
  /// while hosting, so its hotspot holds while the house Wi-Fi stays on and
  /// the move can be announced over that network. Every phone answers only
  /// for itself, so all of them elect the same one; between two that both
  /// can, the fuller battery leads.
  ///
  /// Who hosted last no longer counts: a phone that could not keep both up
  /// led once, and the record of it kept the phone that could from ever
  /// being chosen (2026-10-15: a Galaxy S8 hosting on top of the house
  /// Wi-Fi, its hotspot gone forty seconds in).
  Future<bool> _prefersHostingFor(SavedRoom saved) async {
    final host = GetIt.instance.isRegistered<HotspotHost>()
        ? GetIt.instance<HotspotHost>()
        : null;
    if (host == null) return false;
    final advice = await host.wifiAdvice();
    return advice.concurrent;
  }

  /// Joins the elected host's access point in the middle of a live session.
  ///
  /// Not through the hotspot bridge: its join ends by stopping the Wi-Fi
  /// transport so the channel can bind afresh, which is right before a
  /// channel and fatal inside one. This asks Android to join, then moves the
  /// running sockets onto the new network — the same two steps the link
  /// keeper takes when it rejoins a lost hotspot.
  Future<HotspotJoinResult> _followHotspotHost(
    HotspotCredentials credentials,
  ) async {
    final getIt = GetIt.instance;
    if (!getIt.isRegistered<HotspotJoiner>()) return HotspotJoinResult.declined;
    // Ours goes down before theirs comes up: two Wi-Fi networks of our own
    // make the native bind refuse to pick either.
    if (getIt.isRegistered<HotspotHost>() && getIt<HotspotHost>().isHosting) {
      Logger.diagnostic('carrier: dropping this phone\'s own AP to follow');
      if (getIt.isRegistered<HotspotLinkKeeper>()) {
        await getIt<HotspotLinkKeeper>().release();
      }
      await getIt<HotspotHost>().stop();
    }
    final joined = await getIt<HotspotJoiner>()
        .join(credentials)
        .timeout(
          _followJoinTimeout,
          onTimeout: () => HotspotJoinResult.declined,
        );
    Logger.diagnostic('carrier: follow join=${joined.name}');
    if (joined == HotspotJoinResult.joined &&
        getIt.isRegistered<WifiTransferRepository>()) {
      getIt<WifiTransferRepository>().rebindSockets();
    }
    return joined;
  }

  /// Covers Android's "connect to this network?" prompt waiting on a person.
  static const _followJoinTimeout = Duration(seconds: 45);

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

  /// Whether this phone has a link the Room can run over, switching the
  /// transport to fit it where that is allowed.
  ///
  /// A transport pinned in settings is never traded away here. Pinned to
  /// Bluetooth, a phone still sitting on Wi-Fi used to be switched onto that
  /// Wi-Fi without a word, so the Room "connected" over the network the user
  /// had just said not to use, and failed the moment Wi-Fi went off. Now the
  /// gate refuses instead, and the lobby offers to connect the phones over
  /// the pinned transport. [honourPin] is false only for a Room invite
  /// hand-off, which arranges its own hotspot by design.
  /// The settings pin a Room honours: Guest is a browser-only link, so a
  /// Room treats it as Automatic.
  TransferMode? get _roomPin =>
      RoomTransportChoice.roomPin(_modeStore?.pinnedMode);

  bool get _needsWifiAccess => _roomPin != TransferMode.bluetooth;

  // The mode store rejects paid IP transports without entitlement. Ask before
  // association/readiness, otherwise the network joins but the Room still
  // listens on Bluetooth and eventually reports a misleading bind timeout.
  Future<bool> _ensureWifiAccess({SavedRoom? room}) async {
    final getIt = GetIt.instance;
    if (!getIt.isRegistered<LicenseGate>()) return true;
    final gate = getIt<LicenseGate>();
    if (gate.allows(PremiumFeature.wifiTransport)) return true;
    Logger.diagnostic('room: Wi-Fi access requires subscription');
    final granted = await openSubscriptionGate(
      context,
      PremiumFeature.wifiTransport,
      onFreeAlternative:
          room != null &&
              !RoomAccessPolicy.requiresPremium(
                room.room.confirmedMembers.length,
              )
          ? () => _connectWithBluetooth(room)
          : null,
    );
    return mounted && granted && gate.allows(PremiumFeature.wifiTransport);
  }

  Future<bool> _ensureGroupAccess(SavedRoom room) async {
    if (!RoomAccessPolicy.requiresPremium(room.room.confirmedMembers.length)) {
      return true;
    }
    final getIt = GetIt.instance;
    if (!getIt.isRegistered<LicenseGate>()) return true;
    if (!mounted) return false;
    return await openSubscriptionGate(context, PremiumFeature.groupRooms) &&
        mounted;
  }

  Future<bool> _openLinkGate({bool honourPin = true}) async {
    final probe = _probe;
    final modeStore = _modeStore;
    if (probe == null || modeStore == null) return true;
    final links = await _readLinks();
    if (mounted) setState(() => _links = links);
    final pinned = honourPin
        ? RoomTransportChoice.roomPin(modeStore.pinnedMode)
        : null;
    final link = links.resolve(pinned ?? modeStore.mode);
    if (!link.isUp) {
      Logger.diagnostic('room: readiness stage=local_link_missing');
      return false;
    }
    if (pinned != null && !link.honours(pinned)) {
      Logger.diagnostic(
        'room: readiness stage=pinned_link_missing '
        'pinned=${pinned.key} link=${link.name}',
      );
      return false;
    }
    var mode = link.modeFor(modeStore.mode);
    if (link == LiveLink.wifi &&
        mode == TransferMode.hotspot &&
        !_onArrangedHotspot) {
      // "Wi-Fi" carries a hotspot mode because a joined hotspot *is* Wi-Fi.
      // But this phone is not on one Tarkk arranged: nothing is holding a
      // joined hotspot, so the network is whatever router it is on — the
      // mode is just left over from the last ride. Recorded as hotspot, the
      // Room took the home router for a network it owns and never moved off
      // it (2026-10-12: both phones "connected" at home with no hotspot).
      // Recorded as Wi-Fi, the carrier promotion sees a borrowed network and
      // moves the group onto a hotspot while the router can still carry the
      // announcement.
      mode = TransferMode.wifi;
    }
    if (mode != modeStore.mode) {
      Logger.diagnostic(
        'room: readiness transport_mode=${modeStore.mode.key}->${mode.key}',
      );
      await modeStore.setMode(mode);
      if (modeStore.mode != mode) {
        Logger.diagnostic('room: readiness transport selection rejected');
        return false;
      }
    }
    return true;
  }

  /// Whether the Wi-Fi this phone is on is a hotspot a Tarkk hand-off
  /// joined (or this phone's own), rather than some router it found itself on.
  bool get _onArrangedHotspot {
    final getIt = GetIt.instance;
    try {
      if (getIt.isRegistered<HotspotHost>() && getIt<HotspotHost>().isHosting) {
        return true;
      }
      if (!getIt.isRegistered<HotspotLinkKeeper>()) return true;
      final keeper = getIt<HotspotLinkKeeper>();
      return keeper.credentials != null &&
          keeper.state != HotspotLinkState.idle;
    } catch (_) {
      // Unreadable: leave the mode as it was, which is what this did before.
      return true;
    }
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
        if (widget.rejoin && !widget.ride && !widget.start) {
          _showAttemptingRoom(selected);
          return await _rejoinSelectedRoom(selected);
        }
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
    if (!await _ensureGroupAccess(room)) return _EntryState.lobby(room);
    if ((useHomeWifi || _needsWifiAccess) &&
        !await _ensureWifiAccess(room: room)) {
      return _EntryState.lobby(room);
    }
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
      return _verifiedLiveFor(
        current,
        linkEstablished: true,
        moveOffRouter: false,
      );
    }
    // Before showing any reconnect QR, try the link that is already present.
    // It is only accepted if RoomConnectionReadinessGate receives a signed,
    // bidirectional proof from another member of this exact Room. Merely being
    // on Wi-Fi (including home Wi-Fi) can never pass that gate.
    if (!linkEstablished) {
      final existing = await _verifiedLiveFor(
        current,
        linkEstablished: true,
        readinessTimeout: const Duration(seconds: 4),
      );
      if (existing.live || !mounted) return existing;
      if (existing.failure == _EntryFailure.staleAttempt) return existing;
      if (_guidedReconnectApplies(current)) return _reconnect(current);
      if (_roomPin == TransferMode.bluetooth &&
          _roomBluetoothApplies(current)) {
        return _connectOverBluetooth(current);
      }
      return existing;
    }
    return _verifiedLiveFor(current, linkEstablished: true);
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
    // A transport pinned in Advanced settings is the user's call. Guest is a
    // browser link and says nothing about how two phones meet.
    return _roomPin != TransferMode.bluetooth;
  }

  // ---------------------------------------------------------------- rejoin

  /// How long the quiet way back gets to join the network it was on before
  /// the code screen takes over.
  static const _quietJoinTimeout = Duration(seconds: 25);

  /// Goes back into the call this phone dropped out of, over the connection
  /// it ran on and nothing else.
  ///
  /// - Home Wi-Fi: the network is still there, so it simply starts on it.
  /// - Joined someone's shared connection: joins it again with the details
  ///   remembered from the call, with no code, while that phone still holds
  ///   it up. If it has gone, the code screen opens on the scanning side and
  ///   the other phone shows its code from the live screen.
  /// - Shared the connection itself: that went with the app, and a new one
  ///   has new details, so this phone shares again and shows its code.
  /// - Bluetooth, or no ticket: the ordinary Start, which already re-dials.
  ///
  /// A transport picked in settings since then still wins over the ticket.
  Future<_EntryState> _rejoinSelectedRoom(SavedRoom room) async {
    if (!await _ensureGroupAccess(room)) return _EntryState.lobby(room);
    final ticket = await _rejoinTickets.read();
    if (ticket == null ||
        ticket.roomId != room.room.id ||
        !ticket.isFresh(DateTime.now())) {
      Logger.diagnostic('room: rejoin without ticket');
      return _startSelectedRoom(room);
    }
    Logger.diagnostic(
      'room: rejoin mode=${ticket.mode.key} side=${ticket.side.name} '
      'remembered=${ticket.credentials != null}',
    );
    final pin = _roomPin;
    if (pin == TransferMode.bluetooth &&
        ticket.mode != TransferMode.bluetooth) {
      return _startSelectedRoom(room);
    }
    if (ticket.mode.requiresPremium && !await _ensureWifiAccess(room: room)) {
      return _EntryState.lobby(room);
    }
    switch (ticket.mode) {
      case TransferMode.wifi:
        return _startSelectedRoom(room, useHomeWifi: true);
      case TransferMode.hotspot:
        if (ticket.side == SessionRole.host) {
          return _reconnect(room, showCode: true);
        }
        final credentials = ticket.credentials;
        if (credentials != null && await _quietJoin(credentials)) {
          if (!mounted) return _EntryState.lobby(room);
          final outcome = await _verifiedLiveFor(room, linkEstablished: true);
          if (outcome.live || !mounted) return outcome;
          if (outcome.failure == _EntryFailure.staleAttempt) return outcome;
        }
        if (!mounted) return _EntryState.lobby(room);
        return _reconnect(
          room,
          showCode: false,
          message: context.getString.rejoin_quiet_failed,
        );
      case TransferMode.bluetooth:
      case TransferMode.guest:
        return _startSelectedRoom(room);
    }
  }

  /// Joins the shared connection this phone was on before it dropped out.
  Future<bool> _quietJoin(HotspotCredentials credentials) async {
    _roleStore?.setRole(SessionRole.joiner);
    try {
      final joined = await PreLiveHotspotBootstrap()
          .joinHost(credentials)
          .timeout(_quietJoinTimeout);
      Logger.diagnostic('room: rejoin quiet join=${joined.name}');
      if (joined != HotspotJoinResult.joined) return false;
      await _modeStore?.setMode(TransferMode.hotspot);
      return true;
    } on TimeoutException {
      Logger.diagnostic('room: rejoin quiet join timed out');
      return false;
    } catch (e) {
      Logger.log('Quiet rejoin failed: $e');
      return false;
    }
  }

  /// Remembers this call, so if the app stops without a Leave the next start
  /// can offer the way back. Written every time a Room goes live.
  Future<void> _saveRejoinTicket(SavedRoom room) async {
    final mode = _modeStore?.mode;
    if (mode == null || mode == TransferMode.guest) return;
    final side = _roleStore?.role ?? SessionRole.unknown;
    HotspotCredentials? credentials;
    if (mode == TransferMode.hotspot &&
        side == SessionRole.joiner &&
        GetIt.instance.isRegistered<HotspotLinkKeeper>()) {
      credentials = GetIt.instance<HotspotLinkKeeper>().credentials;
    }
    await _rejoinTickets.save(
      RoomRejoinTicket(
        roomId: room.room.id,
        mode: mode,
        side: side,
        at: DateTime.now(),
        credentials: credentials,
      ),
    );
  }

  /// "Scan their code" from the live screen: the person who dropped out was
  /// sharing the connection, and it went with their app. This screen swaps
  /// for the camera, joins the new connection their phone shows, and comes
  /// back live: no lobby, no Start.
  void _scanPeerCodeFromLive(SavedRoom room) {
    Logger.diagnostic('room: rejoin scan from live');
    _abandonReconnectAttempt();
    setState(() {
      _attemptRoom = room;
      _entry = _reconnect(room, showCode: false);
    });
  }

  // ------------------------------------------------------------ one-scan invite

  /// Which invite is current. Bumped when one ends, so a late callback from
  /// an older sheet or wait acts on nothing.
  int _inviteToken = 0;
  bool _inviting = false;
  Timer? _inviteGrace;

  /// The newcomer's progress, shown on the open invite sheet. Driven only by
  /// what this phone's link actually sees: their traffic arriving, their
  /// Bluetooth link, their signed hello.
  ValueNotifier<RoomInviteeProgress>? _invitee;

  /// Called whenever another phone is heard on this phone's link while a
  /// readiness wait runs.
  VoidCallback? _onPeerHeard;

  /// How long this phone keeps its link up after the invite sheet is closed
  /// with nobody connected yet. "They scanned — Done" is the usual way the
  /// sheet closes, and the other phone may still be inside Android's join
  /// prompt (8–18 s in the 2026-10-05 logs) when it does.
  static const _inviteGraceAfterClose = Duration(seconds: 45);

  /// Pause before listening again after an attempt ended with nobody there.
  static const _inviteRetryGap = Duration(seconds: 2);

  /// Invite from the lobby, before the Room is live: one scan has to be all
  /// it takes.
  ///
  /// A QR made here used to carry membership and nothing else — no network
  /// is up before a Room goes live — so the person who scanned joined the
  /// Room with no way to reach this phone, and this phone never learned that
  /// anybody had scanned (2026-10-05: "it took too long", then nothing). Now
  /// this phone brings its selected link up first and the code carries it:
  /// the hotspot by default, Bluetooth when that is the Room's transport. The
  /// moment a code people can use is on screen, this phone starts waiting for
  /// the newcomer's signed proof; when it arrives the sheet closes and both
  /// phones are in the call.
  Future<void> _inviteFromLobby(SavedRoom room) async {
    if (_inviting || !mounted) return;
    _inviting = true;
    try {
      final current = await _roomForAction(room);
      if (current == null || !mounted) return;
      final bluetooth = _roomPin == TransferMode.bluetooth;
      final enabled = widget.guidedReconnect ?? Platform.isAndroid;
      // Hosting either link is Android-only. Elsewhere the code carries
      // membership alone, as it always has.
      if (!enabled ||
          (!bluetooth && !await _canHostHotspot()) ||
          !(bluetooth || _hotspotHost != null)) {
        if (!mounted) return;
        await showOneScanRoomInviteSheet(context, repository: _rooms);
        return;
      }
      if (!bluetooth && !await _ensureWifiAccess(room: current)) return;
      if (!mounted) return;

      _endInvite();
      _abandonReconnectAttempt();
      final token = ++_inviteToken;
      final dismiss = Completer<void>();
      var waiting = false;
      var scanInstead = false;
      final invitee = ValueNotifier(RoomInviteeProgress.waiting);
      _invitee = invitee;
      final Future<RoomInviteLink?> link;
      BluetoothInviteHost? bluetoothHost;
      // Try again on the sheet: whatever the failed attempt left half up goes
      // down first, then the same link is raised afresh.
      Future<RoomInviteLink?> relink() async {
        if (!mounted || token != _inviteToken) return null;
        if (bluetooth) {
          await bluetoothHost?.dispose();
          if (!mounted || token != _inviteToken) return null;
          final host = BluetoothInviteHost();
          bluetoothHost = host;
          return host.start();
        }
        await _releaseOwnHotspot();
        if (!mounted || token != _inviteToken) return null;
        _roleStore?.setRole(SessionRole.host);
        final credentials = await _prepareHost();
        if (!mounted || token != _inviteToken) return null;
        return credentials == null ? null : HotspotInviteLink(credentials);
      }

      if (bluetooth) {
        final host = BluetoothInviteHost();
        bluetoothHost = host;
        link = host.start();
      } else {
        _roleStore?.setRole(SessionRole.host);
        // Asked before the sheet: it is a page of its own, and the hotspot
        // that held in the field is the one raised with Wi-Fi already off.
        await _offerWifiOff();
        if (!mounted || token != _inviteToken) return;
        link = _prepareHost().then(
          (credentials) =>
              credentials == null ? null : HotspotInviteLink(credentials),
        );
      }
      Logger.diagnostic(
        'room_invite: link=${bluetooth ? 'bluetooth' : 'hotspot'} preparing',
      );
      final arrived = await showOneScanRoomInviteSheet(
        context,
        repository: _rooms,
        link: link,
        linkKind: bluetooth
            ? LinkPreparingKind.bluetooth
            : LinkPreparingKind.hotspot,
        dismissWhen: dismiss.future,
        invitee: invitee,
        onRetryLink: relink,
        onScanInstead: () => scanInstead = true,
        onShown: () {
          if (token != _inviteToken) return;
          waiting = true;
          Logger.diagnostic('room_invite: code shown, waiting for scan');
          unawaited(
            _awaitInvitee(
              current,
              token: token,
              dismiss: dismiss,
              invitee: invitee,
              bluetoothHost: bluetoothHost,
            ),
          );
        },
      );
      if (!mounted || token != _inviteToken || arrived) return;
      if (scanInstead) {
        // Their phone could not reach this one and is showing its own code:
        // this phone's link and its wait stand down, and the camera opens on
        // the same screen the rider is already looking at.
        Logger.diagnostic('room_invite: swapped to scanning their code');
        _inviteGrace?.cancel();
        _inviteGrace = null;
        _inviteToken++;
        await bluetoothHost?.dispose();
        final fresh = await _roomForAction(current);
        if (!mounted || fresh == null) return;
        _scanPeerCodeFromLive(fresh);
        return;
      }
      if (!waiting) {
        // No usable code was ever shown: nothing to wait for.
        _endInvite(release: true, bluetoothHost: bluetoothHost);
        return;
      }
      _inviteGrace?.cancel();
      _inviteGrace = Timer(_inviteGraceAfterClose, () {
        if (token != _inviteToken) return;
        Logger.diagnostic(
          'room_invite: nobody connected after the sheet closed',
        );
        _endInvite(release: true, bluetoothHost: bluetoothHost);
      });
    } finally {
      _inviting = false;
    }
  }

  /// Waits, behind the invite sheet, for the person who scans to connect.
  Future<void> _awaitInvitee(
    SavedRoom room, {
    required int token,
    required Completer<void> dismiss,
    ValueNotifier<RoomInviteeProgress>? invitee,
    BluetoothInviteHost? bluetoothHost,
  }) async {
    void tell(RoomInviteeProgress progress) {
      if (!mounted || token != _inviteToken) return;
      if (identical(_invitee, invitee)) invitee?.value = progress;
    }

    // The sheet has just opened the newcomer's seat; the proof they send is
    // signed for that seat, so the roster read here has to include it.
    final fresh = await _roomForAction(room);
    if (fresh == null || !mounted || token != _inviteToken) return;
    if (bluetoothHost != null) {
      final linked = await bluetoothHost.awaitJoiner(within: _showCodeTimeout);
      if (!mounted || token != _inviteToken) return;
      if (!linked) {
        _endInvite(release: true, bluetoothHost: bluetoothHost);
        if (!dismiss.isCompleted) dismiss.complete();
        return;
      }
      // Their phone holds a Bluetooth link to this one: they are here.
      tell(RoomInviteeProgress.connecting);
      await _modeStore?.setMode(TransferMode.bluetooth);
    }
    // One attempt can end early without anybody having scanned — the link
    // probe has not caught up with the new hotspot yet, a socket bind races
    // it. The code is still on screen and still good, so keep listening
    // until the code's own deadline rather than closing it on them.
    final deadline = DateTime.now().add(_showCodeTimeout);
    late _EntryState outcome;
    while (true) {
      final remaining = deadline.difference(DateTime.now());
      // Their first datagram on this phone's link is the moment they are
      // arriving; the signed hello that follows is what proves it.
      void heard() => tell(RoomInviteeProgress.connecting);
      _onPeerHeard = heard;
      final attempt = _verifiedLiveFor(
        fresh,
        linkEstablished: true,
        readinessTimeout: remaining,
      );
      _activeStart = attempt;
      try {
        outcome = await attempt;
      } finally {
        if (identical(_onPeerHeard, heard)) _onPeerHeard = null;
      }
      if (identical(_activeStart, attempt)) _activeStart = null;
      if (!mounted || token != _inviteToken) return;
      if (outcome.live || !DateTime.now().isBefore(deadline)) break;
      // That try fell through; the code is still good and back on screen.
      if (bluetoothHost == null) tell(RoomInviteeProgress.waiting);
      await Future<void>.delayed(_inviteRetryGap);
      if (!mounted || token != _inviteToken) return;
    }
    if (outcome.live) {
      // The sheet lands its connected beat before it gives way to the call,
      // so the call opens out of it rather than cutting it off.
      tell(RoomInviteeProgress.connected);
      if (invitee != null && mounted) {
        final beat = AppMotion.reduced(context)
            ? const Duration(milliseconds: 450)
            : ConnectionJourney.establishedBeat;
        await Future<void>.delayed(beat);
        // The call is up either way; only a screen that is gone stops it
        // being shown.
        if (!mounted) return;
      }
    }
    _inviteToken++;
    _inviteGrace?.cancel();
    if (!dismiss.isCompleted) dismiss.complete();
    if (outcome.live) {
      Logger.diagnostic('room_invite: newcomer connected');
      setState(() {
        _attemptRoom = fresh;
        _entry = Future.value(outcome);
      });
      return;
    }
    await bluetoothHost?.dispose();
    unawaited(_releaseOwnHotspot());
  }

  /// Stops listening for an invitee once the person has moved on to
  /// connecting some other way.
  ///
  /// A closed invite sheet keeps its wait running for
  /// [_inviteGraceAfterClose], in case the other person was mid-scan — and
  /// that wait is the attempt in progress, so every Start and Connect tap in
  /// the meantime was swallowed by the "already starting" guard. The lobby
  /// sat there unresponsive for up to 45 seconds, until leaving the Room or
  /// locking the screen happened to end it (2026-10-12 report). A tap is the
  /// clearer signal: the wait ends there. The link it raised stays up, so a
  /// guided step that shows this phone's code reuses it rather than waiting
  /// for a fresh hotspot.
  void _endInviteWait() {
    if (_inviteGrace == null) return;
    Logger.diagnostic('room_invite: closed invite wait ended by a new start');
    _inviteGrace?.cancel();
    _inviteGrace = null;
    _inviteToken++;
    _abandonReconnectAttempt();
  }

  /// Ends the current invite: a wait still running is abandoned and, with
  /// [release], the link raised for it goes back down.
  void _endInvite({bool release = false, BluetoothInviteHost? bluetoothHost}) {
    _inviteGrace?.cancel();
    _inviteGrace = null;
    if (!release) return;
    _inviteToken++;
    _abandonReconnectAttempt();
    unawaited(bluetoothHost?.dispose() ?? Future<void>.value());
    unawaited(_releaseOwnHotspot());
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
    if (!await _ensureWifiAccess()) return _EntryState.lobby(room);
    final token = ++_reconnectToken;
    final local = room.membership.localMemberId;
    final canHost = await _canHostHotspot() && !Platform.isIOS;
    final RoomMemberId? electedHost = showCode == null
        ? await _electedHost(room)
        : null;
    if (!mounted || token != _reconnectToken) return _EntryState.lobby(room);
    final wantsShow = showCode ?? electedHost == local;
    final show = wantsShow && canHost;
    // Read before the screen goes up, so a phone with Wi-Fi off goes straight
    // to the card asking for it. Setting the model first mounted the camera
    // for one frame and tore it straight down again — and a camera closed
    // while it is still opening is how Android ends up reporting it "in use".
    final wifiOff = !show && !await _wifiOnForScan();
    if (!mounted || token != _reconnectToken) return _EntryState.lobby(room);
    final peer = _peerFor(room, electedHost: electedHost);
    final peerName = _memberName(peer);
    Logger.diagnostic(
      'room: reconnect side=${show ? 'show' : 'scan'} '
      'elected=${wantsShow ? 'self' : 'peer'} canHost=$canHost',
    );
    if (wifiOff) Logger.diagnostic('room: reconnect waiting for wifi');
    final s = context.getString;
    _setReconnect(
      room,
      RoomReconnectModel(
        side: show ? RoomReconnectSide.show : RoomReconnectSide.scan,
        peerName: peerName,
        phase: show ? RoomReconnectPhase.preparing : RoomReconnectPhase.waiting,
        canSwitch: show || canHost,
        wifiOff: wifiOff,
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
    // Switching from showing the code to scanning one: the hotspot this phone
    // was holding up has to go, or it stays on the air beside the one being
    // joined and the keeper keeps vouching for credentials nobody will use.
    await _releaseOwnHotspot();
    if (!mounted || token != _reconnectToken) return _EntryState.lobby(room);
    _roleStore?.setRole(SessionRole.joiner);
    // Joining the other phone's connection needs Wi-Fi on. Asked for before
    // the camera opens, not after a scan fails on it.
    if (!await _awaitWifiForScan(token)) return _EntryState.lobby(room);
    _listenWhileScanning(room, token);
    while (true) {
      final waiter = Completer<HotspotCredentials?>();
      _scanWaiter = waiter;
      final credentials = await waiter.future;
      final passive = _passiveLive;
      if (mounted && token == _reconnectToken && passive != null) {
        _passiveLive = null;
        Logger.diagnostic('room: reconnect settled by the link already up');
        return _leaveReconnect(passive);
      }
      if (!mounted || token != _reconnectToken || credentials == null) {
        return _EntryState.lobby(room);
      }
      // The code wins from here: whatever the passive listener was doing on
      // the old network stops before this phone leaves it.
      _stopListeningWhileScanning();
      var joined = await _joinScannedNetwork(credentials);
      if (!mounted || token != _reconnectToken) return _EntryState.lobby(room);
      if (joined == HotspotJoinResult.wifiOff) {
        // Switched off after the camera opened. The code is already in hand,
        // so once Wi-Fi is back this joins with it rather than asking for a
        // second scan.
        _completeScan(false);
        if (!await _awaitWifiForScan(token)) return _EntryState.lobby(room);
        joined = await _joinScannedNetwork(credentials);
        if (!mounted || token != _reconnectToken) {
          return _EntryState.lobby(room);
        }
      }
      // The reason, not a sentence: the screen says it in plain words and,
      // when this phone simply cannot get onto the other one's connection,
      // offers the swap first instead of another scan of the same code.
      final RoomReconnectProblem? problem = switch (joined) {
        HotspotJoinResult.joined => null,
        HotspotJoinResult.wifiOff => RoomReconnectProblem.wifiOff,
        HotspotJoinResult.locationOff => RoomReconnectProblem.locationOff,
        HotspotJoinResult.declined => RoomReconnectProblem.joinDeclined,
      };
      if (problem == null) {
        await _modeStore?.setMode(TransferMode.hotspot);
        _completeScan(true);
        break;
      }
      _updateReconnect(
        (model) => model.copyWith(clearMessage: true, problem: problem),
      );
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
    // The link snaps where the rider is looking, with a fresh camera one tap
    // away, rather than a lobby that would only send them straight back here.
    // The camera is not reopened by itself: a preview lighting up behind the
    // failure reads as if it were still trying.
    _updateReconnect(
      (current) => current.copyWith(
        phase: RoomReconnectPhase.failed,
        clearMessage: true,
        problem: RoomReconnectProblem.noAnswer,
      ),
    );
    return outcome;
  }

  /// A live outcome the passive listener reached while the camera was up.
  _EntryState? _passiveLive;
  bool _passiveListening = false;

  /// How long the scan side keeps listening on the link it already has.
  static const _passiveListenWindow = Duration(minutes: 3);

  /// Keeps listening on whatever link this phone still has while the camera
  /// waits for a code.
  ///
  /// The scan side is where a phone lands after its own attempt gave up — but
  /// "gave up" is only this phone's opinion. The other phone may be a second
  /// away from finishing the same signed hello, still on the same hotspot,
  /// and go live without anybody scanning anything (2026-10-12: one phone in
  /// the call, the other at a camera, until the code was scanned from inside
  /// the call). While this runs, a proof from any Room member on the current
  /// link takes this phone straight into the call, camera and all abandoned.
  void _listenWhileScanning(SavedRoom room, int token) {
    if (_passiveListening || _codeOnly) return;
    _passiveListening = true;
    unawaited(() async {
      try {
        final outcome = await _verifiedLiveAttempt(
          room,
          linkEstablished: true,
          readinessTimeout: _passiveListenWindow,
        );
        if (!mounted || token != _reconnectToken || !outcome.live) return;
        _passiveLive = outcome;
        final waiter = _scanWaiter;
        if (waiter != null && !waiter.isCompleted) waiter.complete(null);
      } finally {
        _passiveListening = false;
      }
    }());
  }

  void _stopListeningWhileScanning() {
    if (!_passiveListening) return;
    _readinessEpoch++;
    _abandonReadinessWaits();
    _announcer?.stop();
    _announcer = null;
    _endCoordinator();
    unawaited(_binding?.close() ?? Future<void>.value());
  }

  Future<HotspotJoinResult> _joinScannedNetwork(
    HotspotCredentials credentials,
  ) async {
    try {
      return await PreLiveHotspotBootstrap().joinHost(credentials);
    } catch (error) {
      Logger.log('Room network scan join failed: $error');
      return HotspotJoinResult.declined;
    }
  }

  /// The longest this phone spends bringing its hotspot up before it says it
  /// could not. Normally a few seconds; Android can also simply never answer,
  /// and that left the phone on a spinner with nothing to press.
  static const _prepareTimeout = Duration(seconds: 60);

  /// Brings this phone's hotspot up, or gives up after [_prepareTimeout].
  Future<HotspotCredentials?> _prepareHost() async {
    await _offerWifiOff();
    if (!mounted) return null;
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

  /// This entry already asked the host to switch Wi-Fi off. Retries and
  /// reconnects inside the same visit don't ask again; the next visit does.
  bool _wifiOffOffered = false;

  /// The longest the hotspot waits for an answer on the Wi-Fi page. Well
  /// inside [_handoffTimeout], so the other end of a hand-off is still
  /// waiting when the credentials arrive.
  static const _wifiOffWait = Duration(seconds: 25);

  /// Asks this phone to switch Wi-Fi off before its hotspot comes up.
  ///
  /// Awaited by [_prepareHost], up to [_wifiOffWait]: a hotspot raised while
  /// Wi-Fi is on and then left running after Wi-Fi goes off is the one the
  /// field logs show dying for its joiner (2026-09-28, twice), while one
  /// raised with Wi-Fi already off held. After the cap the hotspot starts
  /// anyway and the page stays up.
  Future<void> _offerWifiOff() async {
    final host = _hotspotHost;
    if (host == null || _wifiOffOffered || !mounted) return;
    _wifiOffOffered = true;
    try {
      await HotspotWifiOffPage.showIfWifiOn(
        context,
        host,
      ).timeout(_wifiOffWait);
    } on TimeoutException {
      Logger.diagnostic('room: wifi-off page still open, hosting anyway');
    }
  }

  /// How often the Wi-Fi card looks at the radio while it waits for it.
  static const _wifiPoll = Duration(seconds: 1);

  Future<bool> _wifiOnForScan() async {
    final host = _hotspotHost;
    if (host == null) return true;
    try {
      return (await host.wifiAdvice()).wifiEnabled;
    } catch (_) {
      return true;
    }
  }

  /// Holds the scan side on the "turn on Wi-Fi" card until the radio is on.
  ///
  /// Returns false when the attempt was abandoned meanwhile (back, switch,
  /// retry). Where the radio cannot be read — iOS, or no hotspot service —
  /// this says nothing and lets the camera open, as before.
  Future<bool> _awaitWifiForScan(int token) async {
    final host = _hotspotHost;
    if (host == null) return true;
    var shown = _reconnectModel?.wifiOff ?? false;
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
    _abandonReadinessWaits();
    _passiveLive = null;
    _handoffFallback = false;
    _handoffCodeTimer?.cancel();
    // The abandoned attempt may still be unwinding; a later Start must plan
    // afresh rather than be handed its future.
    _activeStart = null;
    _announcer?.stop();
    _announcer = null;
    _endCoordinator();
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

  /// Which phone shows its code when the two reconnect: the Room's creator,
  /// worked out the same way on every phone from the Room itself.
  ///
  /// Not who hosted last. Each phone kept its own record of that, and after a
  /// move both had written themselves down, so both showed a code and nobody
  /// scanned, or one opened its camera at a phone showing nothing
  /// (2026-10-16). The other phone's switch button is still there when the
  /// creator cannot host.
  Future<RoomMemberId?> _electedHost(SavedRoom room) async =>
      RoomHotspotHistory.creatorOf(room);

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
    bool moveOffRouter = true,
  }) async {
    _arrivedByMove = false;
    var outcome = await _verifiedLiveAttempt(
      room,
      linkEstablished: linkEstablished,
      readinessTimeout: readinessTimeout,
    );
    if (moveOffRouter && outcome.live) {
      outcome = await _moveOffRouter(room, outcome);
    }
    if (outcome.live) _watchForFallback(room);
    // A no-op unless a slow hand-off put the code or camera up meanwhile.
    return _settleHandoffFallback(room, outcome);
  }

  // ------------------------------------------------- moving off the router

  /// The move in progress, while its screen is up.
  RoomMigrationProgress? _migrationProgress;
  SavedRoom? _migrationRoom;
  String _migrationPeerName = '';
  Completer<void>? _migrationLanded;
  Completer<void>? _migrationStay;

  /// Completed by the scene's close button on a move off the router.
  Completer<void>? _migrationClose;

  /// The move is playing over a call that is already open.
  bool _migrationFellBack = false;

  /// What the move is taking the phones onto, and whether this phone set off
  /// from a Wi-Fi network (the Bluetooth scene says so when it did).
  RoomMoveCarrier _migrationCarrier = RoomMoveCarrier.hotspot;
  bool _migrationOnWifi = true;

  /// What went wrong, while the move's scene is telling it.
  RoomMigrationFailureCopy? _migrationFailure;
  List<Widget> _migrationActions = const [];

  /// The channel is opening out of the move's own "connected" beat, so the
  /// generic arrival animation would only say it a second time.
  bool _arrivedByMove = false;

  /// A guided step after a move that did not finish connects by its code
  /// alone. Listening on the old link meanwhile would put both phones in the
  /// channel over the very router they were trying to leave.
  bool _codeOnly = false;

  bool get _movesOffRouter =>
      widget.moveOffRouter ?? (Platform.isAndroid || Platform.isIOS);

  /// Takes two phones that have just proven themselves over a shared router
  /// onto one phone's own hotspot, and only then lets the channel open.
  ///
  /// [live] is what the router alone achieved. It is returned as it is when
  /// there is nothing better to move to, and replaced by the guided step when
  /// the move was tried and did not finish. See [RoomCarrierMigration].
  ///
  /// With [fellBack] the channel is already open — the call landed on the
  /// house Wi-Fi, or fell back to it when a hotspot dropped — and the same
  /// flow plays over it, the call carrying on underneath.
  ///
  /// A move that does not finish is told inside the same scene, never by
  /// cutting to another screen: the link snaps, the reason is said, and the
  /// way forward rises in under it — on the phone that would host, "turn off
  /// Wi-Fi" when that is what kept its hotspot from holding, then Try again;
  /// on the other, "continue" to scan its code. Only the person's tap moves
  /// on from there, so nothing retries by itself behind their back.
  Future<_EntryState> _moveOffRouter(
    SavedRoom room,
    _EntryState live, {
    bool fellBack = false,
  }) async {
    if (!_movesOffRouter || !mounted) return live;
    if (_modeStore?.mode != TransferMode.wifi) return live;
    final binding = _binding;
    final mover = binding?.carrierPromotion;
    if (binding == null || mover == null) return live;
    final local = room.membership.localMemberId;
    final proven = <RoomMemberId, RoomPeerProofEvidence>{
      for (final proof in binding.verifiedPeerProofSnapshot)
        if (proof.memberId != local) proof.memberId: proof,
    };
    // Two phones is the ride this is for. A bigger group keeps the
    // in-channel move, which waits for everyone to arrive first.
    if (proven.length != 1) return live;
    final peer = proven.values.single;
    final peerMember = room.room.members
        .where((member) => member.id == peer.memberId)
        .firstOrNull;
    final landed = Completer<void>();
    final stay = Completer<void>();
    final close = Completer<void>();
    setState(() {
      _migrationRoom = room;
      _migrationProgress = const RoomMigrationProgress(RoomMigrationStep.found);
      _migrationPeerName = _memberName(peerMember);
      _migrationLanded = landed;
      _migrationStay = stay;
      _migrationClose = close;
      _migrationFellBack = fellBack;
      _migrationCarrier = RoomMoveCarrier.hotspot;
      _migrationOnWifi = true;
      _migrationFailure = null;
      _migrationActions = const [];
    });
    void clear() {
      if (!mounted || !identical(_migrationLanded, landed)) return;
      setState(() {
        _migrationProgress = null;
        _migrationRoom = null;
        _migrationLanded = null;
        _migrationStay = null;
        _migrationClose = null;
        _migrationFellBack = false;
        _migrationFailure = null;
        _migrationActions = const [];
      });
    }

    while (true) {
      final outcome = await _runMigration(
        mover: mover,
        binding: binding,
        peer: peer,
        landed: landed,
        stay: stay,
        close: close,
      );
      if (!mounted) return _EntryState.lobby(room);
      if (close.isCompleted) {
        return _closeMove(
          room,
          binding,
          live,
          fellBack: fellBack,
          clear: clear,
        );
      }
      switch (outcome.result) {
        case RoomMigrationResult.moved:
          // The channel opens (or carries on) out of the scene's own landing.
          await landed.future.timeout(
            const Duration(seconds: 3),
            onTimeout: () {},
          );
          unawaited(_recordHotspotHost(room, {peer.memberId}));
          unawaited(_saveRejoinTicket(room));
          unawaited(
            ConnectionHistory.registered?.remember(TransferMode.hotspot.key),
          );
          if (!fellBack) _arrivedByMove = true;
          clear();
          return live;
        case RoomMigrationResult.stay:
          if (outcome.noHost) {
            // Nobody could be chosen to share. Said in the scene, not by
            // cutting to the call: the router is not going with them.
            Logger.diagnostic('carrier_move: nobody to host');
            final next = await _migrationNoHost(stay: stay);
            if (!mounted) return _EntryState.lobby(room);
            if (next == _MoveChoice.close) {
              return _closeMove(
                room,
                binding,
                live,
                fellBack: fellBack,
                clear: clear,
              );
            }
            if (next == _MoveChoice.bluetooth) {
              return _moveToBluetooth(room, binding, fellBack, clear);
            }
            if (next == _MoveChoice.retry) {
              setState(() {
                _migrationFailure = null;
                _migrationActions = const [];
                _migrationProgress = const RoomMigrationProgress(
                  RoomMigrationStep.found,
                );
              });
              continue;
            }
            mover.standDown();
          }
          clear();
          return live;
        case RoomMigrationResult.abandoned:
          if (stay.isCompleted && mounted) {
            // "Use Bluetooth instead", while the move was still going.
            return _moveToBluetooth(room, binding, fellBack, clear);
          }
          if (fellBack && mounted) {
            mover.standDown();
            clear();
            return live;
          }
          clear();
          return _EntryState.lobby(room, failure: _EntryFailure.staleAttempt);
        case RoomMigrationResult.needsGuidance:
          final choice = await _migrationFailed(outcome, stay: stay);
          if (!mounted) return _EntryState.lobby(room);
          switch (choice) {
            case _MoveChoice.close:
              return _closeMove(
                room,
                binding,
                live,
                fellBack: fellBack,
                clear: clear,
              );
            case _MoveChoice.bluetooth:
              return _moveToBluetooth(room, binding, fellBack, clear);
            case _MoveChoice.stay:
              // The screen went away; nothing left to show.
              mover.standDown();
              clear();
              return live;
            case _MoveChoice.retry:
              // Back into the same scene, which plays its failure backwards.
              setState(() {
                _migrationFailure = null;
                _migrationActions = const [];
                _migrationProgress = const RoomMigrationProgress(
                  RoomMigrationStep.found,
                );
              });
              continue;
            case _MoveChoice.showCode:
            case _MoveChoice.scan:
              final showCode = choice == _MoveChoice.showCode;
              final s = context.getString;
              final name = _migrationPeerName;
              final message =
                  outcome.failure == RoomCarrierMoveFailure.joinDeclined &&
                      !showCode
                  ? s.carriermove_guided_declined(name)
                  : showCode
                  ? s.carriermove_guided_show(name)
                  : s.carriermove_guided_scan(name);
              _endCoordinator();
              await binding.close();
              if (!mounted) return _EntryState.lobby(room);
              _codeOnly = true;
              // The move's screen stays up until the guided one replaces it.
              final guided = _reconnect(
                room,
                showCode: showCode,
                message: message,
              );
              if (fellBack) {
                // The call this flow was playing over is gone; the guided
                // step is what the entry shows now.
                setState(() => _entry = guided);
              }
              final next = await guided;
              clear();
              return next;
          }
      }
    }
  }

  // ------------------------------------------------- moving onto Bluetooth

  /// Whether this two-phone Room can find its other phone over Bluetooth on
  /// its own, with the move's Bluetooth scene, rather than through the
  /// separate pairing screen.
  bool _roomBluetoothApplies(SavedRoom room) {
    if (!_movesOffRouter || !Platform.isAndroid) return false;
    if (!GetIt.instance.isRegistered<BluetoothTransport>()) return false;
    final local = room.membership.localMemberId;
    return room.room.confirmedMembers.where((m) => m.id != local).length == 1;
  }

  /// Stops the Bluetooth move in flight, when the screen goes away.
  Completer<void>? _bluetoothStop;

  /// How long one side waits for the other to turn up over Bluetooth. The
  /// other person may still be getting their phone out.
  static const _bluetoothFindFor = Duration(minutes: 3);

  /// Connects the two phones of [room] over Bluetooth, told in the move's own
  /// Bluetooth scene from the first beat ("you're on home Wi-Fi") to the
  /// channel opening out of its last.
  ///
  /// No code and no network: each phone works out on its own which of them
  /// listens and what for ([RoomBluetoothRendezvous]); the other searches.
  /// The link is only a way in. The signed Room proofs that follow over it,
  /// the same ones every other way in needs, are what open the channel.
  ///
  /// A failure is told in the same scene with the way forward under it: Try
  /// again, another way to connect (the pairing screen), or back.
  Future<_EntryState> _connectOverBluetooth(SavedRoom room) async {
    final local = room.membership.localMemberId;
    final peer = room.room.confirmedMembers.firstWhere((m) => m.id != local);
    final listener = RoomBluetoothRendezvous.listenerOf(local, peer.id);
    final side = listener == local
        ? RoomMigrationSide.host
        : RoomMigrationSide.joiner;
    final landed = Completer<void>();
    // Only the person (Stop, Back) or the screen going away stops this.
    // Not the readiness waits' own abandon signal: every check over the new
    // link fires it as it starts.
    final stop = Completer<void>();
    _bluetoothStop = stop;
    final stopped = stop.future;
    Logger.diagnostic('room: bluetooth move side=${side.name}');
    void show(RoomMigrationStep step) {
      if (!mounted || !identical(_migrationLanded, landed)) return;
      setState(
        () => _migrationProgress = RoomMigrationProgress(step, side: side),
      );
    }

    setState(() {
      _migrationRoom = room;
      _migrationProgress = const RoomMigrationProgress(RoomMigrationStep.found);
      _migrationPeerName = _memberName(peer);
      _migrationLanded = landed;
      _migrationStay = stop;
      _migrationClose = null;
      _migrationFellBack = false;
      _migrationCarrier = RoomMoveCarrier.bluetooth;
      _migrationOnWifi = _resolvedLink == LiveLink.wifi;
      _migrationFailure = null;
      _migrationActions = const [];
    });
    void clear() {
      if (!mounted || !identical(_migrationLanded, landed)) return;
      setState(() {
        _migrationProgress = null;
        _migrationRoom = null;
        _migrationLanded = null;
        _migrationStay = null;
        _migrationCarrier = RoomMoveCarrier.hotspot;
        _migrationFailure = null;
        _migrationActions = const [];
      });
    }

    var stoppedNow = false;
    unawaited(stopped.then((_) => stoppedNow = true));
    Future<bool> beat(Duration hold) async {
      final reduced = mounted && AppMotion.reduced(context);
      await Future.any([
        Future<void>.delayed(
          reduced ? const Duration(milliseconds: 300) : hold,
        ),
        stopped,
      ]);
      return mounted && !stoppedNow;
    }

    // The first two beats are read, not waited on: what is happening and
    // who listens. Each phone settles the second on its own.
    if (!await beat(const Duration(milliseconds: 1800))) {
      return _stopBluetooth(room, clear);
    }
    show(RoomMigrationStep.electing);
    if (!await beat(const Duration(milliseconds: 1100))) {
      return _stopBluetooth(room, clear);
    }

    while (true) {
      show(RoomMigrationStep.preparing);
      final link = await RoomBluetoothRendezvous.linkFor(
        room: room.room.id,
        listener: listener,
      );
      final failure = side == RoomMigrationSide.host
          ? await _listenOverBluetooth(link, show, stopped)
          : await _searchOverBluetooth(link, show, stopped);
      if (!mounted || stoppedNow) return _stopBluetooth(room, clear);
      _BluetoothMoveFailure? reason = failure;
      if (reason == null) {
        show(RoomMigrationStep.verifying);
        await _modeStore?.setMode(TransferMode.bluetooth);
        final outcome = await _verifiedLiveFor(
          room,
          linkEstablished: true,
          readinessTimeout: const Duration(seconds: 30),
          moveOffRouter: false,
        );
        if (!mounted) return _EntryState.lobby(room);
        if (stoppedNow) return _stopBluetooth(room, clear);
        if (outcome.live) {
          show(RoomMigrationStep.established);
          await landed.future.timeout(
            const Duration(seconds: 3),
            onTimeout: () {},
          );
          unawaited(
            ConnectionHistory.registered?.remember(TransferMode.bluetooth.key),
          );
          _arrivedByMove = true;
          clear();
          return outcome;
        }
        reason = _BluetoothMoveFailure.unconfirmed;
      }
      Logger.diagnostic('room: bluetooth move failed reason=${reason.name}');
      final choice = await _bluetoothMoveFailed(reason, stopped);
      if (!mounted) return _EntryState.lobby(room);
      switch (choice) {
        case _MoveChoice.retry:
          // From a clean radio: a half-made link would answer the next try
          // with "already connected" and skip the finding.
          _resetBluetooth();
          setState(() {
            _migrationFailure = null;
            _migrationActions = const [];
          });
          continue;
        case _MoveChoice.showCode:
        case _MoveChoice.scan:
          // Another way: the pairing screen, as before this flow existed.
          clear();
          _resetBluetooth();
          unawaited(_openBluetoothPairing(room));
          return _EntryState.lobby(room);
        case _MoveChoice.bluetooth:
        case _MoveChoice.stay:
        case _MoveChoice.close:
          return _stopBluetooth(room, clear);
      }
    }
  }

  _EntryState _stopBluetooth(SavedRoom room, void Function() clear) {
    Logger.diagnostic('room: bluetooth move stopped');
    // A check still running over the link would otherwise open the channel
    // behind the person who just said stop.
    _readinessEpoch++;
    _resetBluetooth();
    clear();
    return _EntryState.lobby(room);
  }

  void _resetBluetooth() {
    final getIt = GetIt.instance;
    if (getIt.isRegistered<BluetoothTransport>()) {
      getIt<BluetoothTransport>().reset();
    }
  }

  /// The listening side: advertise, then wait for the other phone to dial.
  Future<_BluetoothMoveFailure?> _listenOverBluetooth(
    BluetoothInviteLink link,
    void Function(RoomMigrationStep step) show,
    Future<void> stopped,
  ) async {
    final host = BluetoothInviteHost(link: link, listenFor: _bluetoothFindFor);
    try {
      final started = await host.start();
      if (started == null) {
        return await _bluetoothReadiness() ?? _BluetoothMoveFailure.off;
      }
      show(RoomMigrationStep.moving);
      final linked = await Future.any([
        host.awaitJoiner(within: _bluetoothFindFor),
        stopped.then((_) => false),
      ]);
      return linked ? null : _BluetoothMoveFailure.notFound;
    } finally {
      await host.dispose();
    }
  }

  /// The searching side: look for the listener until it turns up.
  Future<_BluetoothMoveFailure?> _searchOverBluetooth(
    BluetoothInviteLink link,
    void Function(RoomMigrationStep step) show,
    Future<void> stopped,
  ) async {
    final deadline = DateTime.now().add(_bluetoothFindFor);
    var stoppedNow = false;
    unawaited(stopped.then((_) => stoppedNow = true));
    show(RoomMigrationStep.moving);
    while (!stoppedNow && DateTime.now().isBefore(deadline)) {
      final result = await BluetoothInviteJoiner().join(link, pin: false);
      switch (result) {
        case BluetoothInviteJoinResult.joined:
          return null;
        case BluetoothInviteJoinResult.permissionDenied:
          return _BluetoothMoveFailure.permission;
        case BluetoothInviteJoinResult.locationOff:
          return _BluetoothMoveFailure.location;
        case BluetoothInviteJoinResult.bluetoothOff:
          return _BluetoothMoveFailure.off;
        case BluetoothInviteJoinResult.notFound:
          // Not there yet. Keep looking: the other person may still be
          // opening the Room.
          if (!stoppedNow) {
            await Future<void>.delayed(const Duration(seconds: 1));
          }
      }
    }
    return _BluetoothMoveFailure.notFound;
  }

  /// Why the listening side could not start, when it can be told.
  Future<_BluetoothMoveFailure?> _bluetoothReadiness() async {
    try {
      final ready = await GetIt.instance<BluetoothTransport>().isAdapterReady;
      return ready
          ? _BluetoothMoveFailure.permission
          : _BluetoothMoveFailure.off;
    } catch (_) {
      return null;
    }
  }

  /// Tells a Bluetooth move's failure in its scene and waits for the choice.
  Future<_MoveChoice> _bluetoothMoveFailed(
    _BluetoothMoveFailure reason,
    Future<void> stopped,
  ) {
    final s = context.getString;
    final name = _migrationPeerName;
    final choice = Completer<_MoveChoice>();
    void pick(_MoveChoice value) {
      if (!choice.isCompleted) choice.complete(value);
    }

    unawaited(stopped.then((_) => pick(_MoveChoice.stay)));
    setState(() {
      _migrationFailure = RoomMigrationFailureCopy(
        title: s.btmove_failed_title,
        detail: switch (reason) {
          _BluetoothMoveFailure.notFound => s.btmove_failed_notfound_detail(
            name,
          ),
          _BluetoothMoveFailure.off => s.btmove_failed_off_detail,
          _BluetoothMoveFailure.permission => s.btmove_failed_permission_detail,
          _BluetoothMoveFailure.location => s.btmove_failed_location_detail,
          _BluetoothMoveFailure.unconfirmed => s.btmove_failed_check_detail(
            name,
          ),
        },
      );
      _migrationActions = [
        FilledButton.icon(
          key: const Key('bluetooth-move-retry'),
          onPressed: () => pick(_MoveChoice.retry),
          icon: const Icon(Icons.refresh_rounded),
          label: Text(s.reconnect_retry),
        ),
        OutlinedButton.icon(
          key: const Key('bluetooth-move-another-way'),
          onPressed: () => pick(_MoveChoice.scan),
          icon: const Icon(Icons.bluetooth_searching_rounded),
          label: Text(s.btmove_pair_manually),
        ),
        TextButton(
          key: const Key('bluetooth-move-back'),
          onPressed: () => pick(_MoveChoice.stay),
          child: Text(s.entry_back),
        ),
      ];
    });
    return choice.future;
  }

  // ------------------------------------------- falling back to the router

  StreamSubscription<RoomPeerProofEvidence>? _fallbackWatch;
  StreamSubscription<RoomCarrierStatus>? _fallbackHandover;

  final RoomHotspotFallbackDetector _fallback = RoomHotspotFallbackDetector();
  bool _fallingBack = false;

  /// Watches a call on a hotspot for the moment it ends up back on the house
  /// Wi-Fi without anyone choosing it: the access point dropped (Android
  /// often says nothing when it does) and both phones' Wi-Fi rejoined the
  /// router they started on. The call survives that on its own, which is
  /// exactly why it went unnoticed (2026-10-15: forty seconds on the hotspot,
  /// then the rest of the call over the router, no move ever tried again).
  void _watchForFallback(SavedRoom room) {
    unawaited(_fallbackWatch?.cancel());
    unawaited(_fallbackHandover?.cancel());
    _fallback.reset();
    final binding = _binding;
    if (binding == null || !_movesOffRouter) return;
    final local = room.membership.localMemberId;
    if (_modeStore?.mode == TransferMode.hotspot) {
      for (final proof in binding.verifiedPeerProofSnapshot) {
        if (proof.memberId != local) _fallback.seed(proof.carrierRoute);
      }
    }
    // A planned hand-over to another host changes the route on purpose;
    // the next proof after it is the new normal.
    _fallbackHandover = binding.carrierPromotion?.statusChanges.listen((s) {
      if (s.isHandingOver) _fallback.reset();
    });
    _fallbackWatch = binding.verifiedPeerProofs.listen(
      (proof) => _onLiveProof(room, proof),
    );
  }

  void _onLiveProof(SavedRoom room, RoomPeerProofEvidence proof) {
    if (!mounted || _fallingBack || _migrationProgress != null) return;
    if (proof.memberId == room.membership.localMemberId) return;
    if (room.room.activeMembers.length != 2) return;
    if (_modeStore?.mode != TransferMode.hotspot) {
      _fallback.reset();
      return;
    }
    if (_binding?.carrierPromotion?.status.isHandingOver ?? false) return;
    if (_fallback.observe(proof.carrierRoute)) {
      unawaited(_fallBackOffRouter(room));
    }
  }

  /// The call is back on the router: say so in the move's own scene, over
  /// the call, and take it to a hotspot again.
  Future<void> _fallBackOffRouter(SavedRoom room) async {
    _fallingBack = true;
    try {
      Logger.diagnostic('carrier_move: call fell back off the hotspot');
      await _modeStore?.setMode(TransferMode.wifi);
      final getIt = GetIt.instance;
      // Nothing should try to rejoin a hotspot that is gone.
      if (getIt.isRegistered<HotspotLinkKeeper>()) {
        await getIt<HotspotLinkKeeper>().release();
      }
      final host = _hotspotHost;
      if (host != null && host.isHosting) await host.stop();
      if (!mounted) return;
      await _moveOffRouter(room, _EntryState.live(room: room), fellBack: true);
    } catch (e) {
      Logger.log('Fallback move failed: $e');
    } finally {
      _fallingBack = false;
      _fallback.reset();
    }
  }

  /// One run of the move, with its progress on screen.
  Future<RoomMigrationOutcome> _runMigration({
    required RoomCarrierMover mover,
    required SelectedRoomLiveSessionBinding binding,
    required RoomPeerProofEvidence peer,
    required Completer<void> landed,
    required Completer<void> stay,
    required Completer<void> close,
  }) async {
    final migration = RoomCarrierMigration(
      mover: mover,
      peer: peer.memberId,
      proofs: binding.verifiedPeerProofs,
      previousRoute: peer.carrierRoute,
    );
    final progress = migration.progressChanges.listen((step) {
      if (mounted && identical(_migrationLanded, landed)) {
        setState(() => _migrationProgress = step);
      }
    });
    try {
      return await migration.run(
        abandoned: Future.any([
          _abandonWaits.future,
          stay.future,
          close.future,
        ]),
      );
    } finally {
      await progress.cancel();
      await migration.dispose();
    }
  }

  /// The way off the router that never needs a hotspot: Bluetooth, which is
  /// free and keeps working once the riders leave. Offered in place of
  /// staying on the house Wi-Fi, which never comes with them.
  Widget _useBluetoothButton(VoidCallback onPressed) => TextButton.icon(
    key: const Key('carrier-migration-bluetooth'),
    onPressed: onPressed,
    icon: const Icon(Icons.bluetooth_rounded),
    label: Text(context.getString.carriermove_use_bluetooth),
  );

  /// Leaves the move for Bluetooth: the Wi-Fi session goes, and the two
  /// phones find each other over Bluetooth in its own scene. A call already
  /// open on the router ([fellBack]) is replaced by the one that comes up
  /// over Bluetooth.
  Future<_EntryState> _moveToBluetooth(
    SavedRoom room,
    SelectedRoomLiveSessionBinding binding,
    bool fellBack,
    void Function() clear,
  ) async {
    Logger.diagnostic('carrier_move: moving to bluetooth by request');
    binding.carrierPromotion?.standDown();
    _endCoordinator();
    await binding.close();
    if (!mounted) return _EntryState.lobby(room);
    if (!_roomBluetoothApplies(room)) {
      clear();
      unawaited(_openBluetoothPairing(room));
      final lobby = _EntryState.lobby(room);
      if (fellBack) setState(() => _entry = Future.value(lobby));
      return lobby;
    }
    // The hotspot's scene is not cleared first: the Bluetooth one takes its
    // place in the same beat, so the move turns from one to the other
    // instead of dropping back to the Room between them.
    final next = _connectOverBluetooth(room);
    if (fellBack) setState(() => _entry = next);
    return next;
  }

  /// The scene's close button: the move stops and the person is back where
  /// they were. A call already running over the router carries on under it;
  /// one that never opened goes back to the Room, cleanly, so Start plans
  /// afresh. Whatever access point the move raised comes down with it.
  Future<_EntryState> _closeMove(
    SavedRoom room,
    SelectedRoomLiveSessionBinding binding,
    _EntryState live, {
    required bool fellBack,
    required void Function() clear,
  }) async {
    Logger.diagnostic('carrier_move: closed by the person');
    binding.carrierPromotion?.standDown();
    clear();
    await _releaseOwnHotspot();
    if (fellBack) return live;
    _endCoordinator();
    await binding.close();
    return _EntryState.lobby(room);
  }

  /// The close button over the move's scene.
  void _closeMigration() {
    if (_migrationCarrier == RoomMoveCarrier.bluetooth) {
      // The Bluetooth scene's own stop.
      final stop = _migrationStay;
      if (stop != null && !stop.isCompleted) stop.complete();
      return;
    }
    final close = _migrationClose;
    if (close != null && !close.isCompleted) close.complete();
  }

  /// Tells, in the scene, that neither phone could be chosen to share, and
  /// waits for Try again or Bluetooth ([_MoveChoice.stay] only when the
  /// screen went away).
  Future<_MoveChoice> _migrationNoHost({required Completer<void> stay}) {
    final s = context.getString;
    final choice = Completer<_MoveChoice>();
    void pick(_MoveChoice value) {
      if (!choice.isCompleted) choice.complete(value);
    }

    unawaited(stay.future.then((_) => pick(_MoveChoice.bluetooth)));
    unawaited(_abandonWaits.future.then((_) => pick(_MoveChoice.stay)));
    final close = _migrationClose;
    if (close != null) {
      unawaited(close.future.then((_) => pick(_MoveChoice.close)));
    }
    setState(() {
      _migrationFailure = RoomMigrationFailureCopy(
        title: s.carriermove_failed_title,
        detail: s.carriermove_failed_nohost_detail,
      );
      _migrationActions = [
        FilledButton.icon(
          key: const Key('carrier-migration-retry'),
          onPressed: () => pick(_MoveChoice.retry),
          icon: const Icon(Icons.refresh_rounded),
          label: Text(s.reconnect_retry),
        ),
        _useBluetoothButton(() => pick(_MoveChoice.bluetooth)),
      ];
    });
    return choice.future;
  }

  /// Tells the failure in the move's own scene and waits for the person to
  /// pick the way forward.
  Future<_MoveChoice> _migrationFailed(
    RoomMigrationOutcome outcome, {
    required Completer<void> stay,
  }) async {
    final s = context.getString;
    final name = _migrationPeerName;
    final hosting = outcome.side != RoomMigrationSide.joiner;
    final choice = Completer<_MoveChoice>();
    void pick(_MoveChoice value) {
      if (!choice.isCompleted) choice.complete(value);
    }

    unawaited(stay.future.then((_) => pick(_MoveChoice.bluetooth)));
    unawaited(_abandonWaits.future.then((_) => pick(_MoveChoice.stay)));
    final close = _migrationClose;
    if (close != null) {
      unawaited(close.future.then((_) => pick(_MoveChoice.close)));
    }

    // The phone that would host, still on the house Wi-Fi and unable to keep
    // both up: its hotspot is what dropped. Turning Wi-Fi off is the fix,
    // and Try again carries on the hotspot from there.
    final advice = hosting ? await _hotspotHost?.wifiAdvice() : null;
    if (!mounted) return _MoveChoice.stay;
    final wifiInTheWay =
        advice != null && advice.wifiEnabled && !advice.concurrent;
    Logger.diagnostic(
      'carrier_move: failed side=${outcome.side.name} '
      'reason=${outcome.failure?.name ?? 'unknown'} wifiInTheWay=$wifiInTheWay',
    );

    final stayLink = _useBluetoothButton(() => pick(_MoveChoice.bluetooth));
    setState(() {
      if (hosting) {
        _migrationFailure = RoomMigrationFailureCopy(
          title: wifiInTheWay
              ? s.carriermove_failed_wifi_title
              : s.carriermove_failed_title,
          detail: wifiInTheWay
              ? s.carriermove_failed_wifi_detail(name)
              : s.carriermove_failed_host_detail(name),
        );
        _migrationActions = [
          if (wifiInTheWay)
            _WifiOffButton(
              key: const Key('carrier-migration-wifi-off'),
              host: _hotspotHost,
              onOff: () => pick(_MoveChoice.showCode),
            ),
          if (wifiInTheWay)
            OutlinedButton.icon(
              key: const Key('carrier-migration-retry'),
              onPressed: () => pick(_MoveChoice.retry),
              icon: const Icon(Icons.refresh_rounded),
              label: Text(s.reconnect_retry),
            )
          else
            FilledButton.icon(
              key: const Key('carrier-migration-retry'),
              onPressed: () => pick(_MoveChoice.showCode),
              icon: const Icon(Icons.refresh_rounded),
              label: Text(s.reconnect_retry),
            ),
          stayLink,
        ];
      } else {
        _migrationFailure = RoomMigrationFailureCopy(
          title: s.carriermove_failed_title,
          detail: outcome.failure == RoomCarrierMoveFailure.joinDeclined
              ? s.carriermove_failed_declined_detail(name)
              : s.carriermove_failed_joiner_detail(name),
        );
        _migrationActions = [
          FilledButton.icon(
            key: const Key('carrier-migration-continue'),
            onPressed: () => pick(_MoveChoice.scan),
            icon: const Icon(Icons.qr_code_scanner_rounded),
            label: Text(s.carriermove_continue_joiner),
          ),
          stayLink,
        ];
      }
    });
    return choice.future;
  }

  /// Ends the current Start, connected or not, so the next one plans afresh.
  /// Every caller is leaving the session it belonged to.
  void _endCoordinator() => _coordinator.end(epoch: _coordinator.state.epoch);

  Future<_EntryState> _verifiedLiveAttempt(
    SavedRoom room, {
    required bool linkEstablished,
    Duration? readinessTimeout,
  }) async {
    if (!await _ensureGroupAccess(room)) return _EntryState.lobby(room);
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
      // This flag only permits an IP attachment attempt. It never declares
      // the Room connected: RoomConnectionReadinessGate below still requires
      // a signed bidirectional proof from an expected Room member on the same
      // attachment generation.
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
    _abandonReadinessWaits();
    final abandoned = _abandonWaits.future;
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
      if (!await _openLinkGate(honourPin: !hasProximityHandoff)) {
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
      final onHeard = _onPeerHeard;
      final heardWatch = onHeard == null
          ? null
          : announcer?.heard.listen((_) => onHeard());
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
            peerActivity: announcer?.heard,
            abandoned: abandoned,
          );
      unawaited(heardWatch?.cancel());
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
      unawaited(_saveRejoinTicket(room));
      final transport = _modeStore?.mode.key;
      if (transport != null) {
        unawaited(ConnectionHistory.registered?.remember(transport));
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
      _releaseAnnouncer(announcer, current: readinessEpoch == _readinessEpoch);
      _endCoordinator();
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
        // Bluetooth chosen in settings, on either phone, keeps the Room off
        // any hotspot: the invite's own Bluetooth link becomes the audio link.
        bool useBluetooth;
        try {
          useBluetooth = await proximity.agreeOnBluetooth(roomId: room.room.id);
        } catch (e) {
          Logger.log('Room transport preference exchange failed: $e');
          useBluetooth = _roomPin == TransferMode.bluetooth;
        }
        if (useBluetooth) {
          return _bluetoothHandoff(room, localIsHost: localIsElected);
        }
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
      case RoomTransportKind.guest:
      case null:
        return _EntryFailure.transportPlanMismatch;
    }
  }

  /// Replaces the invite's control socket with the Bluetooth audio link:
  /// the phone that showed the invite hosts, the other re-dials the address
  /// it reached the first time.
  Future<_EntryFailure?> _bluetoothHandoff(
    SavedRoom room, {
    required bool localIsHost,
  }) async {
    final proximity = RoomProximityControlSessionRegistry.instance;
    final address = localIsHost ? null : proximity.peerAddressFor(room.room.id);
    if (!localIsHost && address == null) {
      Logger.diagnostic('room: bluetooth handoff has no peer address');
      return _EntryFailure.transportSetup;
    }
    final BluetoothTransport transport;
    try {
      transport = GetIt.instance<BluetoothTransport>();
    } catch (e) {
      Logger.log('Bluetooth transport unavailable: $e');
      return _EntryFailure.compositionUnavailable;
    }
    Logger.diagnostic(
      'room: bluetooth handoff side=${localIsHost ? 'host' : 'joiner'}',
    );
    // Before the link comes up, so the live session is composed on the
    // Bluetooth transport rather than the Wi-Fi one.
    await _modeStore?.setMode(TransferMode.bluetooth);
    // One Bluetooth socket at a time: the control socket has to go before
    // the audio link can use the radio.
    await proximity.clear(roomId: room.room.id);
    final handoff = BluetoothLinkHandoff(transport);
    final linked = localIsHost
        ? await handoff.host()
        : await handoff.join(address!);
    return linked ? null : _EntryFailure.peerProofMissing;
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

  Future<void> _startRide(SavedRoom room, {bool useHomeWifi = false}) async {
    _endInviteWait();
    if (_askingToStart || _activeStart != null) return;
    _askingToStart = true;
    try {
      final current = await _roomForAction(room);
      if (current == null || !mounted || !await _ensureGroupAccess(current)) {
        return;
      }
      if ((useHomeWifi || _needsWifiAccess) &&
          !await _ensureWifiAccess(room: current)) {
        return;
      }
      if (!mounted) return;
      _codeOnly = false;
      _arrivedByMove = false;
      setState(() {
        _attemptRoom = current;
        _entry = _startSelectedRoom(current, useHomeWifi: useHomeWifi);
      });
    } finally {
      _askingToStart = false;
    }
  }

  Future<void> _connectWithBluetooth(SavedRoom room) async {
    _endInviteWait();
    if (_openingBluetooth) return;
    _openingBluetooth = true;
    try {
      final current = await _roomForAction(room);
      if (current == null || !mounted || !await _ensureGroupAccess(current)) {
        return;
      }
      final store = _modeStore;
      if (store == null) return;
      // This is an explicit free-transport choice, so honour it after pairing
      // and when the Bluetooth screen opens a fresh Room entry.
      await store.setPinnedMode(TransferMode.bluetooth);
      if (!mounted) return;
      if (_roomBluetoothApplies(current) && _migrationProgress == null) {
        // Two phones of one Room: they find each other on their own, in the
        // move's Bluetooth scene, rather than through a pairing screen.
        _codeOnly = false;
        _arrivedByMove = false;
        setState(() {
          _attemptRoom = current;
          _entry = _connectOverBluetooth(current);
        });
        return;
      }
      setState(() {});
      await _openBluetoothPairing(current);
    } finally {
      _openingBluetooth = false;
    }
  }

  /// The pairing screen: pick a nearby phone by hand.
  Future<void> _openBluetoothPairing(SavedRoom room) async {
    if (!mounted) return;
    final intent = _bootstrapIntent(room);
    await context.push(
      '${AppRoutes.bluetoothConnectPath}?intent=${intent.key}',
    );
  }

  Future<SavedRoom?> _roomForAction(SavedRoom room) async {
    try {
      return await _rooms?.get(room.room.id) ?? room;
    } catch (_) {
      if (mounted) {
        setState(
          () => _entry = Future.value(
            _EntryState.lobby(room, failure: _EntryFailure.selectionReadFailed),
          ),
        );
      }
      return null;
    }
  }

  void _stopGroupSession(SavedRoom room) {
    _abandonReconnectAttempt();
    unawaited(_releaseOwnHotspot());
    setState(() {
      _attemptRoom = null;
      _entry = Future.value(_EntryState.lobby(room));
    });
  }

  void _retryInitial() {
    _codeOnly = false;
    _readinessEpoch++;
    _abandonReadinessWaits();
    _reconnectToken++;
    _reconnectModel = null;
    _reconnectRoom = null;
    _announcer?.stop();
    _announcer = null;
    _endCoordinator();
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
    final bluetoothStop = _bluetoothStop;
    if (bluetoothStop != null && !bluetoothStop.isCompleted) {
      bluetoothStop.complete();
    }
    _readinessEpoch++;
    if (!_abandonWaits.isCompleted) _abandonWaits.complete();
    _reconnectToken++;
    _inviteToken++;
    _inviteGrace?.cancel();
    _handoffCodeTimer?.cancel();
    final waiter = _scanWaiter;
    if (waiter != null && !waiter.isCompleted) waiter.complete(null);
    // Already handed off when the Room went live; then the live session owns
    // the socket and this is a no-op.
    _announcer?.stop();
    _announcer = null;
    _endCoordinator();
    unawaited(_linkChanges?.cancel() ?? Future<void>.value());
    unawaited(_fallbackWatch?.cancel() ?? Future<void>.value());
    unawaited(_fallbackHandover?.cancel() ?? Future<void>.value());
    unawaited(_binding?.close() ?? Future<void>.value());
    // Left on purpose (Leave, the alone countdown, back out of the Room): no
    // way back is needed. Only an app that stops never gets here.
    unawaited(_rejoinTickets.clear());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // Every change between the Room, the guided reconnect and a move turns
    // one into the other rather than fading (Pedi, 2026-10-16).
    final String scene;
    final int depth;
    if (_reconnectModel != null) {
      scene = 'reconnect';
      depth = 1;
    } else if (_migrationProgress != null &&
        _migrationRoom != null &&
        !_migrationFellBack) {
      scene = 'move-${_migrationCarrier.name}';
      depth = 1;
    } else {
      scene = 'entry';
      depth = 0;
    }
    return SceneTurn(scene: scene, depth: depth, child: _resolved(context));
  }

  Widget _resolved(BuildContext context) {
    final reconnect = _reconnectModel;
    if (reconnect != null) {
      return FeatureAccessGuard(
        feature: PremiumFeature.wifiTransport,
        onDenied: _cancelReconnect,
        onAccessLost: _cancelReconnect,
        builder: (_) => RoomReconnectView(
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
        ),
      );
    }
    final scene = _migrationScene(context);
    if (scene != null && !_migrationFellBack) return scene;
    return _resolvedEntry(context);
  }

  /// The move's scene, while there is a move to show.
  Widget? _migrationScene(BuildContext context) {
    final moving = _migrationProgress;
    final movingRoom = _migrationRoom;
    if (moving == null || movingRoom == null) return null;
    final landed = _migrationLanded;
    final stay = _migrationStay;
    return RouteExitScope(
      key: const ValueKey('room-carrier-migration'),
      onExit: () => leaveRoomEntry(context),
      child: Scaffold(
        backgroundColor: AppColors.background,
        body: SafeArea(
          child: RoomCarrierMigrationView(
            progress: moving,
            peerName: _migrationPeerName,
            caption: movingRoom.room.name,
            fellBack: _migrationFellBack,
            carrier: _migrationCarrier,
            onHomeWifi: _migrationOnWifi,
            failure: _migrationFailure,
            actions: _migrationActions,
            onEstablished: () {
              if (landed != null && !landed.isCompleted) landed.complete();
            },
            onStay: () {
              if (stay != null && !stay.isCompleted) stay.complete();
            },
            onClose: _closeMigration,
          ),
        ),
      ),
    );
  }

  /// Keeps the call's own page in one place in the tree whether or not a
  /// move is playing over it, so the move coming and going never rebuilds
  /// the call underneath.
  final GlobalKey _livePageKey = GlobalKey(debugLabel: 'room-live-page');

  Widget _withLiveMove(BuildContext context, Widget livePage) {
    final scene = _migrationFellBack ? _migrationScene(context) : null;
    return Stack(
      fit: StackFit.expand,
      children: [
        KeyedSubtree(key: _livePageKey, child: livePage),
        SceneTurn(
          scene: scene == null ? 'no-move' : 'move',
          depth: scene == null ? 0 : 1,
          child: scene ?? const SizedBox.shrink(),
        ),
      ],
    );
  }

  /// Set when the rider leaves a failed scan journey for the lobby.
  bool _journeyDismissed = false;

  /// This entry was reached by scanning an invite, so the scan page's scene
  /// carries on here: the Room handshake is the rest of the same link.
  bool get _tellsJourney => widget.start && !_journeyDismissed;

  JourneyLink get _journeyLink => switch (_modeStore?.mode) {
    // Until this entry has read the link for itself, it is the one the scan
    // was drawing.
    null when widget.carryOver != null => widget.carryOver!.link,
    TransferMode.bluetooth => JourneyLink.bluetooth,
    TransferMode.wifi => JourneyLink.sharedWifi,
    _ =>
      _resolvedLink == LiveLink.bluetooth
          ? JourneyLink.bluetooth
          : JourneyLink.hotspot,
  };

  Widget _journeyScaffold(
    BuildContext context,
    SavedRoom? room, {
    required JourneyStage stage,
    String? problem,
    List<Widget> actions = const [],
  }) {
    final s = context.getString;
    final failed = stage == JourneyStage.failed;
    return Scaffold(
      key: const ValueKey('room-entry-journey'),
      backgroundColor: AppColors.background,
      body: SafeArea(
        child: ConnectionJourney(
          key: const ValueKey('room-entry-journey-scene'),
          stage: stage,
          link: _journeyLink,
          continued: true,
          caption: room?.room.name ?? widget.carryOver?.caption,
          title: failed ? s.journey_failed_title : s.journey_handshake_title,
          detail: failed
              ? (problem ?? s.room_start_failed)
              : s.journey_handshake_detail,
          actions: actions,
        ),
      ),
    );
  }

  Widget _resolvedEntry(BuildContext context) => FutureBuilder<_EntryState>(
    future: _entry,
    builder: (context, snapshot) {
      final (scene, depth) = _entrySceneOf(snapshot);
      return SceneTurn(
        scene: scene,
        depth: depth,
        child: _entryBody(context, snapshot),
      );
    },
  );

  /// Which state of the entry [snapshot] shows, and how far in it is, so a
  /// change of state turns rather than cuts.
  (String, int) _entrySceneOf(AsyncSnapshot<_EntryState> snapshot) {
    if (snapshot.connectionState != ConnectionState.done) {
      final room = _attemptRoom;
      if ((room != null || widget.carryOver != null) && _tellsJourney) {
        return ('journey', 1);
      }
      return room != null ? ('lobby', 0) : ('waiting', 0);
    }
    if (snapshot.hasError) return ('recover', 0);
    final state = snapshot.data ?? const _EntryState.invalidSelection();
    if (state.live) return ('live', 2);
    final room = state.room;
    if (room != null && state.failure != null && _tellsJourney) {
      return ('journey', 1);
    }
    if (room != null) return ('lobby', 0);
    return state.failure != null ? ('recover', 0) : ('invalid', 0);
  }

  Widget _entryBody(BuildContext context, AsyncSnapshot<_EntryState> snapshot) {
    if (snapshot.connectionState != ConnectionState.done) {
      final room = _attemptRoom;
      if ((room != null || widget.carryOver != null) && _tellsJourney) {
        return RouteExitScope(
          onExit: () => leaveRoomEntry(context),
          child: _journeyScaffold(context, room, stage: JourneyStage.linking),
        );
      }
      if (room != null) {
        return RouteExitScope(
          onExit: () => leaveRoomEntry(context),
          child: SelectedRoomLobby(
            room: room,
            connectionPhase: RoomConnectionUiPhase.connecting,
            requiresPremium: _needsWifiAccess,
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
      Widget livePage = CarrierStatusScope(
        controller: _binding?.carrierPromotion,
        child: WalkieTalkiePage.buildPage(),
      );
      final room = state.room;
      final mode = _modeStore?.mode;
      // Legacy setup pages already acknowledge their network. Room-first
      // entry reaches this point only after the signed peer proof is verified.
      // A scan's own journey ends here too: the link it showed being made
      // locks in before the channel opens out of it.
      if (room != null &&
          !_arrivedByMove &&
          (!widget.ride || _tellsJourney) &&
          (mode == TransferMode.wifi ||
              mode == TransferMode.hotspot ||
              (_tellsJourney && mode == TransferMode.bluetooth))) {
        livePage = NetworkConnectionArrival(
          key: ValueKey(
            'network-arrival-${room.room.id.value}-$_readinessEpoch',
          ),
          mode: mode!,
          roomName: room.room.name,
          child: livePage,
        );
      }
      livePage = _withLiveMove(context, livePage);
      final binding = _binding;
      final runtime = binding?.runtime;
      if (room != null && binding != null && runtime != null) {
        return RoomGroupAccessGuard(
          room: room,
          repository: _rooms,
          onBlocked: _stopGroupSession,
          builder: (_) => RoomLiveRejoinScope(
            onScanPeerCode: () => _scanPeerCodeFromLive(room),
            child: RoomConnectionStatusScope(
              room: room,
              runtime: runtime,
              peerProofs: binding.verifiedPeerProofs,
              initialPeerProofs: binding.verifiedPeerProofSnapshot,
              child: livePage,
            ),
          ),
        );
      }
      return livePage;
    }
    final room = state.room;
    if (room != null && state.failure != null && _tellsJourney) {
      // The scan's link did not come up. Said where the rider is already
      // looking, with the next step first: the other phone is usually
      // still there, so trying again is the common fix; a fresh code is
      // the fallback; the lobby is one tap away.
      return RouteExitScope(
        onExit: () => leaveRoomEntry(context),
        child: _journeyScaffold(
          context,
          room,
          stage: JourneyStage.failed,
          problem: _failureMessage(context, state.failure),
          actions: [
            FilledButton(
              key: const Key('room-journey-retry'),
              onPressed: () => _startRide(room),
              child: Text(context.getString.retry),
            ),
            OutlinedButton(
              key: const Key('room-journey-scan-again'),
              onPressed: () => context.go(AppRoutes.roomQrJoinPath),
              child: Text(context.getString.journey_scan_again),
            ),
            TextButton(
              key: const Key('room-journey-not-now'),
              onPressed: () => setState(() => _journeyDismissed = true),
              child: Text(context.getString.journey_not_now),
            ),
          ],
        ),
      );
    }
    if (room != null) {
      return RouteExitScope(
        onExit: () => leaveRoomEntry(context),
        child: SelectedRoomLobby(
          room: room,
          link: _resolvedLink,
          mode: _modeStore?.mode,
          failureMessage: _failureMessage(context, state.failure),
          requiresPremium: _needsWifiAccess,
          onUseBluetooth: () => unawaited(_connectWithBluetooth(room)),
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
              (_roomPin == TransferMode.bluetooth
                      ? !(_links?.bluetooth ?? false) ||
                            _offersConnect(state.failure)
                      : _resolvedLink != LiveLink.bluetooth ||
                            _offersConnect(state.failure)) &&
                  !RoomProximityControlSessionRegistry.instance.hasRoom(
                    room.room.id,
                  )
              ? () {
                  if (_roomPin == TransferMode.bluetooth ||
                      _resolvedLink == LiveLink.bluetooth) {
                    unawaited(_connectWithBluetooth(room));
                  } else {
                    unawaited(_startRide(room));
                  }
                }
              : null,
          onInvite: () => _inviteFromLobby(room),
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
  }
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
    child: _visible ? const SignalLoader() : const SizedBox.shrink(),
  );
}

/// The way forward a person picked after a move that did not finish.
/// The way forward from a move: [stay] only when the screen went away.
/// [close] is the scene's close button: stop the move and go back.
enum _MoveChoice { retry, showCode, scan, bluetooth, stay, close }

/// Why a move onto Bluetooth stopped.
enum _BluetoothMoveFailure { notFound, off, permission, location, unconfirmed }

/// "Turn off Wi-Fi", which then waits — visibly — for it to be off.
///
/// Opens the system's Wi-Fi switch (the floating panel where there is one,
/// so this screen stays in view) and watches for the radio to go down, so
/// the move carries on by itself the moment it does: no second tap, no
/// "done" to confirm.
class _WifiOffButton extends StatefulWidget {
  const _WifiOffButton({required this.host, required this.onOff, super.key});

  final HotspotHost? host;
  final VoidCallback onOff;

  @override
  State<_WifiOffButton> createState() => _WifiOffButtonState();
}

class _WifiOffButtonState extends State<_WifiOffButton>
    with WidgetsBindingObserver {
  Timer? _poll;
  bool _waiting = false;
  bool _done = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed && _waiting) unawaited(_check());
  }

  Future<void> _press() async {
    final host = widget.host;
    if (host == null) return;
    setState(() => _waiting = true);
    await host.openWifiPanel();
    _poll?.cancel();
    _poll = Timer.periodic(const Duration(seconds: 1), (_) => _check());
    unawaited(_check());
  }

  Future<void> _check() async {
    final advice = await widget.host?.wifiAdvice();
    if (!mounted || _done || advice == null || advice.wifiEnabled) return;
    _done = true;
    _poll?.cancel();
    Logger.diagnostic('carrier_move: wifi turned off, carrying on');
    widget.onOff();
  }

  @override
  void dispose() {
    _poll?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final s = context.getString;
    return FilledButton.icon(
      onPressed: _waiting ? null : _press,
      icon: AnimatedSwitcher(
        duration: AppMotion.chip,
        child: _waiting
            ? const SizedBox.square(
                key: ValueKey('waiting'),
                dimension: 18,
                child: CircularProgressIndicator(strokeWidth: 2),
              )
            : const Icon(Icons.wifi_off_rounded, key: ValueKey('off')),
      ),
      label: Text(
        _waiting ? s.carriermove_wifi_off_waiting : s.carriermove_wifi_off,
      ),
    );
  }
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

/// A start that could not even be attempted, told in the same scene every
/// other failed connection is told in: the link reaching out and snapping,
/// the reason under it, and the way forward rising in after.
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
      backgroundColor: AppColors.background,
      body: SafeArea(
        child: ConnectionJourney(
          stage: JourneyStage.failed,
          link: JourneyLink.hotspot,
          title: s.journey_failed_title,
          detail: message,
          actions: [
            FilledButton.icon(
              key: const Key('room-entry-retry'),
              onPressed: onRetry,
              icon: const Icon(Icons.refresh_rounded),
              label: Text(s.retry),
            ),
            OutlinedButton(onPressed: onBack, child: Text(s.entry_back)),
          ],
        ),
      ),
    );
  }
}

/// The Room picked to start is gone (left, removed, or never saved), said in
/// the connection scene rather than as a bare line on an empty page.
class _InvalidRoomSelection extends StatelessWidget {
  const _InvalidRoomSelection({required this.onBack});

  final VoidCallback onBack;

  @override
  Widget build(BuildContext context) {
    final s = context.getString;
    return Scaffold(
      backgroundColor: AppColors.background,
      body: SafeArea(
        child: ConnectionJourney(
          stage: JourneyStage.failed,
          link: JourneyLink.hotspot,
          title: s.entry_room_unavailable_title,
          detail: s.entry_room_unavailable,
          actions: [
            FilledButton.icon(
              onPressed: onBack,
              icon: const Icon(Icons.arrow_back_rounded),
              label: Text(s.entry_back),
            ),
          ],
        ),
      ),
    );
  }
}
