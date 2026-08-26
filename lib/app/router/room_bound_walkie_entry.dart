import 'dart:async';

import 'package:flutter/material.dart';
import 'package:get_it/get_it.dart';

import '../../feature/room/api/room_api.dart';
import '../../feature/transfer/api/transfer_api.dart';
import '../../feature/walkie/api/walkie_api.dart';

/// Composition-root bridge between a durable selected Room and the legacy
/// Walkie surface while transport/session migration proceeds incrementally.
///
/// The Room binding is prepared before [WalkieTalkiePage] starts, so the
/// transport's first health events cannot race past the RoomSession adapter.
/// With no valid selected Room we deliberately preserve the existing quick
/// access behavior instead of inventing or auto-selecting a hidden Room.
class RoomBoundWalkieEntry extends StatefulWidget {
  const RoomBoundWalkieEntry({super.key});

  static Widget buildPage() => const RoomBoundWalkieEntry();

  @override
  State<RoomBoundWalkieEntry> createState() => _RoomBoundWalkieEntryState();
}

class _RoomBoundWalkieEntryState extends State<RoomBoundWalkieEntry> {
  late final SelectedRoomLiveSessionBinding _binding;
  late final Future<void> _prepare;

  @override
  void initState() {
    super.initState();
    _binding = SelectedRoomLiveSessionBinding(
      rooms: GetIt.instance<RoomRepository>(),
      transfer: GetIt.instance<TransferRepository>(),
      modeStore: GetIt.instance<TransferModeStore>(),
    );
    _prepare = _binding
        .open(sessionId: _newSessionId())
        .then<void>((_) {})
        .catchError((Object _) {
          // Room binding is an architectural state boundary, not a reason to
          // strand the user before the existing channel troubleshooting UI.
          // Invalid/absent saved Room state already fails closed in the
          // binding; storage errors preserve legacy entry for this session.
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
  Widget build(BuildContext context) => FutureBuilder<void>(
    future: _prepare,
    builder: (context, snapshot) {
      if (snapshot.connectionState != ConnectionState.done) {
        return const Scaffold(body: Center(child: CircularProgressIndicator()));
      }
      return WalkieTalkiePage.buildPage();
    },
  );
}
