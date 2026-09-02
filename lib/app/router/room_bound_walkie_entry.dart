import 'dart:async';

import 'package:flutter/material.dart';
import 'package:get_it/get_it.dart';
import 'package:go_router/go_router.dart';

import '../../core/motion/app_motion.dart';
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
class RoomBoundWalkieEntry extends StatefulWidget {
  const RoomBoundWalkieEntry({super.key});

  static Widget buildPage() => const RoomBoundWalkieEntry();

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

  Future<_EntryState> _resolveInitialEntry() async {
    if (!_compose()) return const _EntryState.live();
    final rooms = _rooms;
    try {
      final selected = await SelectedRoomLobbyResolver(rooms!).resolve();
      if (selected != null) return _EntryState.lobby(selected);
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

  String _newSessionId() =>
      'room-live-${DateTime.now().microsecondsSinceEpoch.toRadixString(36)}';

  @override
  void dispose() {
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
    switchOutCurve: AppMotion.easeOut,
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
        return _BackToRooms(
          onBack: () => leaveRoomEntry(context),
          child: SelectedRoomLobby(
            room: room,
            onStartRide: () => _startRide(room),
            onBack: () => leaveRoomEntry(context),
          ),
        );
      }
      return _BackToRooms(
        onBack: () => leaveRoomEntry(context),
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
void leaveRoomEntry(BuildContext context) {
  if (context.canPop()) {
    context.pop();
  } else {
    context.go(AppRoutes.roomsPath);
  }
}

/// Gives the system back gesture somewhere to go.
///
/// The on-screen control is only half the fix: the gesture is how most people
/// actually leave a screen, and with nothing under this route on the stack an
/// unhandled back closed the app. `canPop: false` routes both through the same
/// answer, so the gesture and the chevron cannot disagree about where "out"
/// is.
///
/// No confirmation, unlike the live channel's: nothing has been started here
/// that leaving could tear down.
class _BackToRooms extends StatelessWidget {
  const _BackToRooms({required this.onBack, required this.child});

  final VoidCallback onBack;
  final Widget child;

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: false,
    onPopInvokedWithResult: (didPop, _) {
      if (!didPop) onBack();
    },
    child: child,
  );
}

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
