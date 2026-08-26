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
    );
    _entry = _resolveInitialEntry();
  }

  Future<_EntryState> _resolveInitialEntry() async {
    final selected = await SelectedRoomLobbyResolver(_rooms).resolve();
    if (selected != null) return _EntryState.lobby(selected);
    await _binding.open(sessionId: _newSessionId());
    return const _EntryState.live();
  }

  Future<_EntryState> _startSelectedRoom(SavedRoom room) async {
    // Re-resolve immediately before going live. The user may have archived or
    // left this Room from another surface while the lobby was open; stale
    // readiness must never start a session for an invalid durable membership.
    final current = await SelectedRoomLobbyResolver(_rooms).resolve();
    if (current == null || current.room.id != room.room.id) {
      return const _EntryState.invalidSelection();
    }
    await _binding.open(sessionId: _newSessionId());
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
        return _SelectedRoomLobby(
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

class _SelectedRoomLobby extends StatelessWidget {
  const _SelectedRoomLobby({required this.room, required this.onStartRide});

  final SavedRoom room;
  final VoidCallback onStartRide;

  @override
  Widget build(BuildContext context) {
    final fa = Localizations.localeOf(context).languageCode.toLowerCase() == 'fa';
    final members = room.room.members
        .where((member) => member.isActive)
        .toList(growable: false);
    return Scaffold(
      appBar: AppBar(title: Text(room.room.name)),
      body: SafeArea(
        child: ListView(
          key: const Key('selected-room-lobby'),
          padding: const EdgeInsets.all(20),
          children: [
            Text(
              fa ? 'آماده شروع ارتباط' : 'Ready to start',
              style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                fontWeight: FontWeight.w800,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              fa
                  ? 'تا وقتی «شروع ارتباط» را نزنید، هیچ هات‌اسپات، میکروفن یا اتصال زنده‌ای شروع نمی‌شود.'
                  : 'No hotspot, microphone, or live transport starts until you press Start ride.',
            ),
            const SizedBox(height: 20),
            Semantics(
              header: true,
              child: Text(
                fa ? 'اعضای اتاق (${members.length})' : 'Room members (${members.length})',
                style: Theme.of(context).textTheme.titleMedium?.copyWith(
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
            const SizedBox(height: 8),
            for (final member in members)
              ListTile(
                dense: true,
                contentPadding: EdgeInsets.zero,
                leading: const Icon(Icons.person_outline_rounded),
                title: Text(
                  member.displayName.trim().isEmpty
                      ? (fa ? 'عضو اتاق' : 'Room member')
                      : member.displayName,
                ),
                subtitle: member.id == room.membership.localMemberId
                    ? Text(fa ? 'شما' : 'You')
                    : null,
              ),
            const SizedBox(height: 20),
            FilledButton.icon(
              key: const Key('selected-room-start-ride'),
              onPressed: onStartRide,
              icon: const Icon(Icons.play_arrow_rounded),
              label: Text(fa ? 'شروع ارتباط' : 'Start ride'),
            ),
          ],
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
    final fa = Localizations.localeOf(context).languageCode.toLowerCase() == 'fa';
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
