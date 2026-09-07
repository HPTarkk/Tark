import 'dart:async';

import 'package:flutter/material.dart';

import '../../domain/entity/held_seat_name.dart';
import '../../domain/entity/room.dart';
import '../../domain/entity/room_session.dart';
import '../../domain/service/room_connection_readiness_gate.dart';
import '../../domain/service/room_session_runtime.dart';

/// Product-level connection states for a Room member.
///
/// These names intentionally contain no carrier vocabulary. Wi-Fi, hotspot,
/// Bluetooth, roles, addresses and credentials are implementation details; the
/// Room UI only answers what is happening with the people in the Room.
enum RoomConnectionUiPhase {
  invited,
  confirming,
  readyToConnect,
  connecting,
  connected,
  reconnecting,
}

/// Live Room state shared with the Walkie surface after verified entry.
///
/// A member becomes [RoomConnectionUiPhase.connected] only when their signed
/// route proof belongs to the current attachment generation. Replacing the
/// attachment therefore turns old evidence into reconnecting/connecting rather
/// than silently carrying a stale "connected" badge forward.
class RoomConnectionStatusScope extends StatefulWidget {
  const RoomConnectionStatusScope({
    required this.room,
    required this.runtime,
    required this.peerProofs,
    required this.initialPeerProofs,
    required this.child,
    super.key,
  });

  final SavedRoom room;
  final RoomSessionRuntime runtime;
  final Stream<RoomPeerProofEvidence> peerProofs;
  final Iterable<RoomPeerProofEvidence> initialPeerProofs;
  final Widget child;

  static RoomConnectionStatusData? maybeOf(BuildContext context) => context
      .dependOnInheritedWidgetOfExactType<_RoomConnectionStatusInherited>()
      ?.data;

  @override
  State<RoomConnectionStatusScope> createState() =>
      _RoomConnectionStatusScopeState();
}

class _RoomConnectionStatusScopeState extends State<RoomConnectionStatusScope> {
  late RoomSession _session = widget.runtime.state;
  final Map<RoomMemberId, int> _proofGenerationByMember = {};
  StreamSubscription<RoomSession>? _sessionSubscription;
  StreamSubscription<RoomPeerProofEvidence>? _proofSubscription;

  @override
  void initState() {
    super.initState();
    for (final proof in widget.initialPeerProofs) {
      _proofGenerationByMember[proof.memberId] = proof.attachmentGeneration;
    }
    _sessionSubscription = widget.runtime.changes.listen((session) {
      if (mounted) setState(() => _session = session);
    });
    _proofSubscription = widget.peerProofs.listen((proof) {
      if (!mounted) return;
      setState(() {
        _proofGenerationByMember[proof.memberId] = proof.attachmentGeneration;
      });
    });
  }

  @override
  void dispose() {
    unawaited(_sessionSubscription?.cancel());
    unawaited(_proofSubscription?.cancel());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return _RoomConnectionStatusInherited(
      data: RoomConnectionStatusData(
        room: widget.room,
        session: _session,
        proofGenerationByMember: Map.unmodifiable(_proofGenerationByMember),
      ),
      child: widget.child,
    );
  }
}

@immutable
class RoomConnectionStatusData {
  const RoomConnectionStatusData({
    required this.room,
    required this.session,
    required this.proofGenerationByMember,
  });

  final SavedRoom room;
  final RoomSession session;
  final Map<RoomMemberId, int> proofGenerationByMember;

  int get attachmentGeneration => session.attachment.generation;

  RoomConnectionUiPhase get overallPhase => switch (session.phase) {
    RoomSessionPhase.live => RoomConnectionUiPhase.connected,
    RoomSessionPhase.degraded || RoomSessionPhase.recoveringTransport =>
      RoomConnectionUiPhase.reconnecting,
    RoomSessionPhase.open => RoomConnectionUiPhase.connecting,
    RoomSessionPhase.left => RoomConnectionUiPhase.reconnecting,
  };

  RoomConnectionUiPhase phaseFor(RoomMember member) {
    if (member.pending) {
      return isHeldSeatPlaceholder(member.displayName)
          ? RoomConnectionUiPhase.invited
          : RoomConnectionUiPhase.confirming;
    }

    if (member.id == room.membership.localMemberId) return overallPhase;

    final provenGeneration = proofGenerationByMember[member.id];
    if (session.phase == RoomSessionPhase.live &&
        provenGeneration == attachmentGeneration) {
      return RoomConnectionUiPhase.connected;
    }

    if (session.phase == RoomSessionPhase.degraded ||
        session.phase == RoomSessionPhase.recoveringTransport) {
      return RoomConnectionUiPhase.reconnecting;
    }

    return RoomConnectionUiPhase.connecting;
  }
}

class _RoomConnectionStatusInherited extends InheritedWidget {
  const _RoomConnectionStatusInherited({
    required this.data,
    required super.child,
  });

  final RoomConnectionStatusData data;

  @override
  bool updateShouldNotify(_RoomConnectionStatusInherited oldWidget) =>
      oldWidget.data.session != data.session ||
      oldWidget.data.room != data.room ||
      !_sameProofs(
        oldWidget.data.proofGenerationByMember,
        data.proofGenerationByMember,
      );
}

bool _sameProofs(Map<RoomMemberId, int> a, Map<RoomMemberId, int> b) {
  if (identical(a, b)) return true;
  if (a.length != b.length) return false;
  for (final entry in a.entries) {
    if (b[entry.key] != entry.value) return false;
  }
  return true;
}
