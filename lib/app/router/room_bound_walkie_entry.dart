import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:get_it/get_it.dart';
import 'package:go_router/go_router.dart';

import '../../core/motion/app_motion.dart';
import '../../core/router/route_exit.dart';
import '../../core/router/routes.dart';
import '../../core/utils/logger.dart';
import '../../feature/room/api/room_api.dart';
import '../../feature/room/presentation/widget/carrier_status_scope.dart';
import '../../feature/transfer/api/transfer_api.dart';
import '../../feature/walkie/api/walkie_api.dart';

/// Composition-root bridge between a durable selected Room and the legacy
/// Walkie surface while transport/session migration proceeds incrementally.
///
/// A valid selected Room now gets a read-only pre-live lobby first. Merely
/// opening that lobby starts no transport, microphone or hotspot. The Room
/// binding and live Walkie surface begin only after the explicit Start ride
/// action. With no valid selected Room we deliberately preserve the existing
/// quick-access behavior instead of inventing or auto-selecting a hidden Room.
///
/// **A Room may not go live over nothing.** Everything below the lobby assumes
/// a link exists: the binding attaches the Room to "the current transport",
/// the failover runtime waits for that transport to fail, and the channel
/// opens the microphone. With no Wi-Fi, no access point of our own and no
/// Bluetooth peer, all three of those are running against a transport that was
/// never there — and the screen the user is left looking at is a channel with
/// one person in it, which reads as the app being broken rather than as the
/// phone not being connected to anything. So the link is checked here, and a
/// device without one is sent to the screen that can get it one instead.
class RoomBoundWalkieEntry extends StatefulWidget {
  const RoomBoundWalkieEntry({super.key, this.ride = false});

  /// Set by the pages that exist to establish a link, on their way back here.
  ///
  /// Finishing the hotspot bridge or a Bluetooth pairing ends with the user
  /// tapping "Enter channel" — they have already said what they want, and
  /// stopping them at the lobby to ask again is the second confirmation of
  /// one decision. Everywhere else (Landing, the room list, a fresh QR join)
  /// still opens the lobby, which is the pause it was built to be.
  final bool ride;

  static Widget buildPage({bool ride = false}) =>
      RoomBoundWalkieEntry(ride: ride);

  @override
  State<RoomBoundWalkieEntry> createState() => _RoomBoundWalkieEntryState();
}

class _RoomBoundWalkieEntryState extends State<RoomBoundWalkieEntry> {
  /// Null when this bridge could not be composed at all. Nothing about Room
  /// state is inferred from that — it means only that the live surface below
  /// has to be reached without it.
  RoomRepository? _rooms;
  SelectedRoomLiveSessionBinding? _binding;
  late Future<_EntryState> _entry;

  /// Resolved separately from the binding, and tolerated missing on its own.
  /// A composition without a probe cannot answer "is there a link", and the
  /// pre-existing behaviour — trust the user and open the channel — is the
  /// only honest thing left to do with that.
  LiveLinkProbe? _probe;
  TransferModeStore? _modeStore;

  /// What the last read said, for the lobby to show. Null until the first
  /// read lands, which is the difference between "no link" and "not asked
  /// yet" — one of those is a reason to change what a button says and the
  /// other is a reason to leave it alone.
  LiveLinkSnapshot? _links;
  StreamSubscription<void>? _linkChanges;

  @override
  void initState() {
    super.initState();
    // Deliberately not resolved in initState: a throw there takes the whole
    // route down to a blank screen, on every transport, with nothing in the
    // log to say why — which is exactly what a stale generated DI config did
    // when `RoomRepository` was missing from it. The channel is the product;
    // this bridge is scaffolding around it and must never be able to stand in
    // front of it.
    _entry = _resolveInitialEntry();
  }

  /// Composes the Room bridge, or gives up on it.
  ///
  /// Returns false when the surrounding wiring cannot supply what the bridge
  /// needs. The caller then goes straight to the live channel, which is the
  /// behavior this route had before the lobby existed.
  bool _compose() {
    _composeLinkProbe();
    if (_binding != null) return true;
    try {
      final rooms = GetIt.instance<RoomRepository>();
      _binding = SelectedRoomLiveSessionBinding(
        rooms: rooms,
        transfer: GetIt.instance<TransferRepository>(),
        modeStore: GetIt.instance<TransferModeStore>(),
        hotspotHost: GetIt.instance<HotspotHost>(),
        hotspotLinkKeeper: GetIt.instance<HotspotLinkKeeper>(),
      );
      _rooms = rooms;
      return true;
    } catch (e) {
      // Loud, because the alternative is a user watching the channel not open
      // and a log with nothing in it.
      Logger.diagnostic('room: live binding unavailable — entering directly');
      Logger.log('Room-bound walkie entry could not compose: $e');
      return false;
    }
  }

  /// Resolves the link probe and starts watching it.
  ///
  /// Kept out of the binding's try block above on purpose: those two failures
  /// have different consequences, and folding them together would have a
  /// missing Room repository silently take the link check down with it.
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
    // No probe is not "no link": a composition that cannot answer the question
    // must not be allowed to answer it wrongly, and the pre-existing behaviour
    // — the user knows what they set up, open the channel — is what it falls
    // back to. `_gateOpen` is what turns this into a decision.
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

  /// The last read, resolved against the transport in effect — or null when
  /// there is nothing to resolve it with, which the lobby reads as "say
  /// nothing about the link" rather than as "there is none".
  LiveLink? get _resolvedLink {
    final links = _links;
    final modeStore = _modeStore;
    if (links == null || modeStore == null) return null;
    return links.resolve(modeStore.mode);
  }

  /// Whether a Room may go live right now, and on what.
  ///
  /// Also the only place the transport is allowed to move: a phone that is on
  /// Bluetooth while the app is still set to Wi-Fi from last week would
  /// otherwise open a channel on a repository with no link under it. The mode
  /// is left exactly alone whenever it already fits — see [LiveLink.modeFor],
  /// which is the half of this that is testable without a radio.
  Future<bool> _openLinkGate() async {
    final probe = _probe;
    final modeStore = _modeStore;
    if (probe == null || modeStore == null) return true;
    final links = await _readLinks();
    if (mounted) setState(() => _links = links);
    final link = links.resolve(modeStore.mode);
    if (!link.isUp) {
      Logger.diagnostic('room: refused live entry — no link');
      return false;
    }
    final mode = link.modeFor(modeStore.mode);
    if (mode != modeStore.mode) {
      Logger.diagnostic(
        'room: transport ${modeStore.mode.key} -> ${mode.key} for ${link.name}',
      );
      await modeStore.setMode(mode);
    }
    return true;
  }

  Future<_EntryState> _resolveInitialEntry() async {
    if (!_compose()) return const _EntryState.live();
    final rooms = _rooms;
    try {
      final selected = await SelectedRoomLobbyResolver(rooms!).resolve();
      if (selected != null) {
        // The lobby is the default, and stays it. `ride` is the one caller
        // that has already earned the channel — it only ever comes from a
        // screen whose entire purpose was establishing the link this then
        // checks for.
        if (widget.ride && await _openLinkGate()) {
          return await _liveFor(selected);
        }
        return _EntryState.lobby(selected);
      }
    } catch (_) {
      // Storage/readiness lookup must not strand legacy quick access. This is
      // the same fail-open-to-existing-live-surface behavior this composition
      // root had before the lobby existed; it does not fabricate Room state.
    }
    try {
      await _binding?.open(sessionId: _newSessionId());
    } catch (_) {
      // Binding errors likewise preserve the established troubleshooting/live
      // path. Invalid Room state already fails closed inside the binding.
    }
    return const _EntryState.live();
  }

  Future<_EntryState> _startSelectedRoom(SavedRoom room) async {
    // Re-resolve immediately before going live. The user may have archived or
    // left this Room from another surface while the lobby was open; stale
    // readiness must never start a session for an invalid durable membership.
    final rooms = _rooms;
    if (rooms == null) return const _EntryState.live();
    try {
      final current = await SelectedRoomLobbyResolver(rooms).resolve();
      if (current == null || current.room.id != room.room.id) {
        return const _EntryState.invalidSelection();
      }
    } catch (_) {
      return const _EntryState.invalidSelection();
    }
    // The backstop, for the same reason the re-resolve above is one: the lobby
    // reads the link when it draws, and a radio can go down between drawing a
    // button and somebody pressing it. The lobby is where the check is
    // *offered* — it turns Start ride into a way of getting connected — and
    // this is where it is enforced. Falling back to the lobby rather than to
    // an error: it re-reads on the way in and will say what is missing.
    if (!await _openLinkGate()) return _EntryState.lobby(room);
    return _liveFor(room);
  }

  Future<_EntryState> _liveFor(SavedRoom room) async {
    try {
      await _binding?.open(sessionId: _newSessionId());
    } catch (_) {
      // Do not strand the user because the architectural Room binding failed;
      // preserve the pre-existing live troubleshooting surface for this run.
    }
    return const _EntryState.live();
  }

  void _startRide(SavedRoom room) {
    setState(() {
      _entry = _startSelectedRoom(room);
    });
  }

  /// Sends a Room with no link to the screen that can get it one.
  ///
  /// Pushed rather than replacing, so the bridge's own back arrow comes back
  /// here — and so the room the user picked is still selected when they
  /// return. Which screen, and which side of it, is [ConnectRoute]'s
  /// decision; what this contributes is the intent, and a Room already knows
  /// that: the phone that hands out the invite code is the phone the others
  /// are gathering around, so it is the one that should be making the
  /// network. It only ever *preselects* — every one of those screens can
  /// still be stepped back to its own role picker.
  void _connect(BuildContext context, SavedRoom room) {
    final links = _links ?? LiveLinkSnapshot.none;
    final intent = room.membership.canManageInvites
        ? ChannelIntent.create
        : ChannelIntent.join;
    // Two different questions, and [ConnectRoute] has always had two answers.
    // A phone with a link that still cannot reach anybody must not be handed
    // to the advisor: the advisor weighs what this device *can* do, and on a
    // phone sitting on a café Wi-Fi its honest answer includes using that same
    // Wi-Fi — which is the thing that just failed. This call site ran the
    // ladder for both cases, so the way out of "we are on different networks"
    // could route back to the network it was an escape from.
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
        // The same platform constants LandingState.conditions and
        // pinnedPlanFor read, for the same reason: they cannot change while
        // the app runs, so threading them through DI would buy a seam nothing
        // needs.
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

  String _newSessionId() =>
      'room-live-${DateTime.now().microsecondsSinceEpoch.toRadixString(36)}';

  @override
  void dispose() {
    unawaited(_linkChanges?.cancel() ?? Future<void>.value());
    unawaited(_binding?.close() ?? Future<void>.value());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AnimatedSwitcher(
    // Whatever this resolves to — lobby, live channel, or the invalid-selection
    // notice — arrives over the wait rather than replacing it in one frame.
    // This is the seam a blank screen appeared in once; a crossfade makes the
    // handover visible instead of instantaneous, which is worth more here than
    // anywhere else in the app.
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
        // Nothing above is supposed to throw past its own catch, so this is
        // the unknown case — and the live channel is the right answer to it.
        // "This room is no longer available" would be a claim about Room state
        // that a failure here does not support.
        Logger.log('Room-bound walkie entry failed: ${snapshot.error}');
        return CarrierStatusScope(
          controller: _binding?.carrierPromotion,
          child: WalkieTalkiePage.buildPage(),
        );
      }
      final state = snapshot.data ?? const _EntryState.invalidSelection();
      if (state.live) {
        // The channel is several layers below the thing that owns the carrier
        // controller, so the status is published from here rather than
        // threaded through every constructor in between.
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
            // Null while the first read is still in flight, and while no
            // probe could be composed at all. Both mean "do not claim
            // anything about the link", which is a different screen from
            // "there is no link".
            link: _resolvedLink,
            // The half the link cannot answer on its own: whether the
            // association was arranged between these phones or merely found.
            // Read from the same store the gate resolves against, so the two
            // can never disagree about what this device is doing.
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

/// Leaves a pre-live Room surface — the lobby, or the invalid-selection notice.
///
/// Neither has started anything, so neither asks a question on the way out;
/// that is the whole difference between this and the live channel's leave
/// control, which wears the same chevron over a confirmation.
///
/// `maybePop` on its own was the dead end. The room list, room creation and
/// the join scanner all arrive here with `go`, which *replaces* the stack — so
/// there is routinely nothing to pop, the control did nothing, and Android's
/// back gesture closed the app instead. Falling through to the room list is an
/// "up" rather than a "back": it is the surface this room was chosen on, and
/// the one place all of those paths came through.
///
/// The rule itself is [exitRouteTo], because this fix has a sting in its tail:
/// the `go` below leaves the room list stackless in turn, and that screen then
/// had no way back of its own. Both ends now use the same primitive.
void leaveRoomEntry(BuildContext context) =>
    exitRouteTo(context, AppRoutes.roomsPath);

/// A spinner that only appears if the wait is long enough to notice.
///
/// Room resolution is a couple of storage reads and usually finishes inside a
/// frame or two. A spinner shown for 80ms and then removed is a flash, and a
/// flash reads as a fault — the user sees *something went wrong and recovered*
/// rather than *that was instant*. So nothing is drawn at all until the delay
/// passes, and then it fades up.
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
    final fa =
        Localizations.localeOf(context).languageCode.toLowerCase() == 'fa';
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
                  fa
                      ? 'این اتاق دیگر برای شروع ارتباط در دسترس نیست.'
                      : 'This room is no longer available to start.',
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 16),
                OutlinedButton(
                  onPressed: onBack,
                  child: Text(fa ? 'بازگشت' : 'Back'),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
