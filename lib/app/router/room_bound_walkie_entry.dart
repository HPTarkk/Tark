import 'dart:async';

import 'package:flutter/material.dart';
import 'package:get_it/get_it.dart';

import '../../feature/room/api/room_api.dart';
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
  late final RoomRepository _rooms;
  late final SelectedRoomLiveSessionBinding _binding;
  late Future<_EntryState> _entry;

  @override
  void initState() {
    super.initState();
    _rooms = GetIt.instance<RoomRepository>();
    _binding = SelectedRoomLiveSessionBinding(
      rooms: _rooms,
      transfer: GetIt.instance<TransferRepository>(),
      modeStore: GetIt.instance<TransferModeStore>(),
      hotspotHost: GetIt.instance<HotspotHost>(),
      hotspotLinkKeeper: GetIt.instance<HotspotLinkKeeper>(),
    );
    _entry = _resolveInitialEntry();
  }

  Future<_EntryState> _resolveInitialEntry() async {
    try {
      final selected = await SelectedRoomLobbyResolver(_rooms).resolve();
      if (selected != null) return _EntryState.lobby(selected);
    } catch (_) {
      // Storage/readiness lookup must not strand legacy quick access. This is
      // the same fail-open-to-existing-live-surface behavior this composition
      // root had before the lobby existed; it does not fabricate Room state.
    }
    try {
      await _binding.open(sessionId: _newSessionId());
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
    try {
      final current = await SelectedRoomLobbyResolver(_rooms).resolve();
      if (current == null || current.room.id != room.room.id) {
        return const _EntryState.invalidSelection();
      }
    } catch (_) {
      return const _EntryState.invalidSelection();
    }
    try {
      await _binding.open(sessionId: _newSessionId());
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
    unawaited(_binding.close());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => FutureBuilder<_EntryState>(
    future: _entry,
    builder: (context, snapshot) {
      if (snapshot.connectionState != ConnectionState.done) {
        return const Scaffold(body: Center(child: CircularProgressIndicator()));
      }
      final state = snapshot.data ?? const _EntryState.invalidSelection();
      if (state.live) return WalkieTalkiePage.buildPage();
      final room = state.room;
      if (room != null) {
        return SelectedRoomLobby(
          room: room,
          onStartRide: () => _startRide(room),
        );
      }
      return _InvalidRoomSelection(
        onBack: () => Navigator.of(context).maybePop(),
      );
    },
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
