import '../entity/room.dart';

enum RoomParticipantState {
  invited,
  joining,
  connected,
  reconnecting,
  unreachable,
  left,
}

final class RoomParticipantPresence {
  const RoomParticipantPresence({
    required this.memberId,
    required this.state,
    required this.attachmentGeneration,
    this.lastInboundAt,
    this.lastOutboundConfirmedAt,
    this.reconnectDeadline,
  });

  final RoomMemberId memberId;
  final RoomParticipantState state;
  final int attachmentGeneration;
  final DateTime? lastInboundAt;
  final DateTime? lastOutboundConfirmedAt;
  final DateTime? reconnectDeadline;

  bool get hasBidirectionalEvidence =>
      lastInboundAt != null && lastOutboundConfirmedAt != null;

  RoomParticipantPresence copyWith({
    RoomParticipantState? state,
    int? attachmentGeneration,
    DateTime? lastInboundAt,
    DateTime? lastOutboundConfirmedAt,
    DateTime? reconnectDeadline,
    bool clearReconnectDeadline = false,
  }) => RoomParticipantPresence(
    memberId: memberId,
    state: state ?? this.state,
    attachmentGeneration: attachmentGeneration ?? this.attachmentGeneration,
    lastInboundAt: lastInboundAt ?? this.lastInboundAt,
    lastOutboundConfirmedAt:
        lastOutboundConfirmedAt ?? this.lastOutboundConfirmedAt,
    reconnectDeadline: clearReconnectDeadline
        ? null
        : reconnectDeadline ?? this.reconnectDeadline,
  );
}

/// Deterministic live-presence state for durable Room members.
///
/// No IP, SSID, Bluetooth address or socket is stored here. A transport
/// attachment can be replaced by advancing [attachmentGeneration] while the
/// stable RoomMemberId and roster row remain unchanged.
final class RoomPresenceTracker {
  RoomPresenceTracker({
    this.reconnectGrace = const Duration(seconds: 12),
    this.evidenceFreshFor = const Duration(seconds: 8),
  });

  final Duration reconnectGrace;
  final Duration evidenceFreshFor;
  final Map<RoomMemberId, RoomParticipantPresence> _participants = {};
  bool _disposed = false;

  List<RoomParticipantPresence> get participants =>
      List.unmodifiable(_participants.values);

  RoomParticipantPresence? get(RoomMemberId id) => _participants[id];

  void addInvited(RoomMemberId id, {required int attachmentGeneration}) {
    _ensureOpen();
    _participants.putIfAbsent(
      id,
      () => RoomParticipantPresence(
        memberId: id,
        state: RoomParticipantState.invited,
        attachmentGeneration: attachmentGeneration,
      ),
    );
  }

  void markJoining(RoomMemberId id, {required int attachmentGeneration}) {
    _ensureOpen();
    final current = _participants[id];
    if (current != null && attachmentGeneration < current.attachmentGeneration) {
      return;
    }
    _participants[id] = RoomParticipantPresence(
      memberId: id,
      state: RoomParticipantState.joining,
      attachmentGeneration: attachmentGeneration,
      lastInboundAt: current?.lastInboundAt,
      lastOutboundConfirmedAt: current?.lastOutboundConfirmedAt,
    );
  }

  void observeInbound(
    RoomMemberId id, {
    required DateTime at,
    required int attachmentGeneration,
  }) {
    _observe(
      id,
      at: at,
      attachmentGeneration: attachmentGeneration,
      inbound: true,
    );
  }

  void observeOutboundConfirmation(
    RoomMemberId id, {
    required DateTime at,
    required int attachmentGeneration,
  }) {
    _observe(
      id,
      at: at,
      attachmentGeneration: attachmentGeneration,
      inbound: false,
    );
  }

  void _observe(
    RoomMemberId id, {
    required DateTime at,
    required int attachmentGeneration,
    required bool inbound,
  }) {
    _ensureOpen();
    final current = _participants[id];
    if (current != null && attachmentGeneration < current.attachmentGeneration) {
      return;
    }
    final base = current ??
        RoomParticipantPresence(
          memberId: id,
          state: RoomParticipantState.joining,
          attachmentGeneration: attachmentGeneration,
        );
    if (base.state == RoomParticipantState.left) return;
    final inboundAt = inbound ? at : base.lastInboundAt;
    final outboundAt = inbound ? base.lastOutboundConfirmedAt : at;
    final connected = _freshPair(inboundAt, outboundAt, at);
    _participants[id] = RoomParticipantPresence(
      memberId: id,
      state: connected
          ? RoomParticipantState.connected
          : RoomParticipantState.joining,
      attachmentGeneration: attachmentGeneration,
      lastInboundAt: inboundAt,
      lastOutboundConfirmedAt: outboundAt,
    );
  }

  void unexpectedLoss(
    RoomMemberId id, {
    required DateTime at,
    required int attachmentGeneration,
  }) {
    _ensureOpen();
    final current = _participants[id];
    if (current == null || current.state == RoomParticipantState.left) return;
    if (attachmentGeneration < current.attachmentGeneration) return;
    _participants[id] = current.copyWith(
      state: RoomParticipantState.reconnecting,
      attachmentGeneration: attachmentGeneration,
      reconnectDeadline: at.add(reconnectGrace),
    );
  }

  void explicitLeave(
    RoomMemberId id, {
    required int attachmentGeneration,
  }) {
    _ensureOpen();
    final current = _participants[id];
    if (current == null) return;
    if (attachmentGeneration < current.attachmentGeneration) return;
    _participants[id] = current.copyWith(
      state: RoomParticipantState.left,
      attachmentGeneration: attachmentGeneration,
      clearReconnectDeadline: true,
    );
  }

  /// Re-evaluates tombstones and bidirectional freshness using injected time.
  /// Callers own scheduling so the domain itself leaks no timers.
  void advance(DateTime now) {
    _ensureOpen();
    for (final entry in _participants.entries.toList(growable: false)) {
      final current = entry.value;
      if (current.state == RoomParticipantState.left) continue;
      final deadline = current.reconnectDeadline;
      if (current.state == RoomParticipantState.reconnecting &&
          deadline != null &&
          !now.isBefore(deadline)) {
        _participants[entry.key] = current.copyWith(
          state: RoomParticipantState.unreachable,
          clearReconnectDeadline: true,
        );
        continue;
      }
      if (current.state == RoomParticipantState.connected &&
          !_freshPair(
            current.lastInboundAt,
            current.lastOutboundConfirmedAt,
            now,
          )) {
        _participants[entry.key] = current.copyWith(
          state: RoomParticipantState.reconnecting,
          reconnectDeadline: now.add(reconnectGrace),
        );
      }
    }
  }

  void replaceAttachment(int nextGeneration) {
    _ensureOpen();
    for (final entry in _participants.entries.toList(growable: false)) {
      final current = entry.value;
      if (current.state == RoomParticipantState.left) continue;
      if (nextGeneration <= current.attachmentGeneration) continue;
      _participants[entry.key] = RoomParticipantPresence(
        memberId: current.memberId,
        state: RoomParticipantState.reconnecting,
        attachmentGeneration: nextGeneration,
        lastInboundAt: current.lastInboundAt,
        lastOutboundConfirmedAt: current.lastOutboundConfirmedAt,
      );
    }
  }

  bool _freshPair(DateTime? inbound, DateTime? outbound, DateTime now) {
    if (inbound == null || outbound == null) return false;
    return now.difference(inbound) <= evidenceFreshFor &&
        now.difference(outbound) <= evidenceFreshFor;
  }

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _participants.clear();
  }

  void _ensureOpen() {
    if (_disposed) throw StateError('RoomPresenceTracker is disposed');
  }
}
