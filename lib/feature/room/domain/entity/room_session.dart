import 'transport_attachment.dart';

enum RoomSessionPhase { open, live, degraded, recoveringTransport, left }

/// Transport-independent identity and user-visible state for one live use of a
/// room.
///
/// The opaque [roomId] is intentionally not an IP address, SSID, Bluetooth
/// address, or display name. #45 will introduce the durable Room repository;
/// this boundary only requires that whatever identifies the logical room is
/// stable while connectivity underneath it changes.
class RoomSession {
  const RoomSession({
    required this.roomId,
    required this.sessionId,
    required this.localMemberId,
    required this.phase,
    required this.attachment,
    required this.memberIds,
    required this.isMuted,
    this.recoveryReason,
  });

  factory RoomSession.open({
    required String roomId,
    required String sessionId,
    required String localMemberId,
    Iterable<String> memberIds = const [],
    bool isMuted = false,
  }) {
    return RoomSession(
      roomId: roomId,
      sessionId: sessionId,
      localMemberId: localMemberId,
      phase: RoomSessionPhase.open,
      attachment: const TransportAttachment.detached(),
      memberIds: Set.unmodifiable({localMemberId, ...memberIds}),
      isMuted: isMuted,
    );
  }

  final String roomId;
  final String sessionId;
  final String localMemberId;
  final RoomSessionPhase phase;
  final TransportAttachment attachment;
  final Set<String> memberIds;
  final bool isMuted;
  final String? recoveryReason;

  bool get hasLeft => phase == RoomSessionPhase.left;
  bool get isLogicallyPresent => !hasLeft;

  RoomSession startAttachment({
    required TransportKind kind,
    String? role,
    String? reason,
  }) {
    _ensurePresent();
    final nextGeneration = attachment.generation + 1;
    return _copy(
      phase: RoomSessionPhase.recoveringTransport,
      recoveryReason: reason,
      attachment: TransportAttachment(
        kind: kind,
        phase: TransportAttachmentPhase.attaching,
        generation: nextGeneration,
        role: role,
        reason: reason,
      ),
    );
  }

  RoomSession attachmentReady({required int generation, String? role}) {
    _ensurePresent();
    if (!_isCurrentGeneration(generation)) return this;
    final kind = attachment.kind;
    if (kind == null) return this;
    return _copy(
      phase: RoomSessionPhase.live,
      clearRecoveryReason: true,
      attachment: attachment.copyWith(
        phase: TransportAttachmentPhase.attached,
        role: role,
        clearReason: true,
      ),
    );
  }

  RoomSession attachmentDegraded({required int generation, String? reason}) {
    _ensurePresent();
    if (!_isCurrentGeneration(generation)) return this;
    return _copy(
      phase: RoomSessionPhase.degraded,
      recoveryReason: reason,
      attachment: attachment.copyWith(
        phase: TransportAttachmentPhase.degraded,
        reason: reason,
      ),
    );
  }

  RoomSession beginTransportRecovery({
    required int generation,
    String? reason,
  }) {
    _ensurePresent();
    if (!_isCurrentGeneration(generation)) return this;
    return _copy(
      phase: RoomSessionPhase.recoveringTransport,
      recoveryReason: reason,
      attachment: attachment.copyWith(
        phase: TransportAttachmentPhase.recovering,
        reason: reason,
      ),
    );
  }

  /// Starts a replacement transport while keeping room/session/membership and
  /// mute state untouched. The old native attachment becomes stale because the
  /// generation increments before the replacement is exposed.
  RoomSession replaceTransport({
    required TransportKind kind,
    String? role,
    String? reason,
  }) {
    _ensurePresent();
    return startAttachment(kind: kind, role: role, reason: reason);
  }

  RoomSession attachmentFailed({required int generation, String? reason}) {
    _ensurePresent();
    if (!_isCurrentGeneration(generation)) return this;
    return _copy(
      phase: RoomSessionPhase.recoveringTransport,
      recoveryReason: reason,
      attachment: attachment.copyWith(
        phase: TransportAttachmentPhase.failed,
        reason: reason,
      ),
    );
  }

  RoomSession setMuted(bool value) {
    _ensurePresent();
    return _copy(isMuted: value);
  }

  RoomSession updateMembers(Iterable<String> ids) {
    _ensurePresent();
    return _copy(memberIds: Set.unmodifiable({localMemberId, ...ids}));
  }

  RoomSession leave() {
    if (hasLeft) return this;
    return _copy(
      phase: RoomSessionPhase.left,
      clearRecoveryReason: true,
      attachment: TransportAttachment(
        kind: attachment.kind,
        phase: TransportAttachmentPhase.disposed,
        generation: attachment.generation,
        role: attachment.role,
      ),
    );
  }

  bool _isCurrentGeneration(int generation) =>
      generation == attachment.generation;

  void _ensurePresent() {
    if (hasLeft) {
      throw StateError('A left RoomSession cannot accept new transitions.');
    }
  }

  RoomSession _copy({
    RoomSessionPhase? phase,
    TransportAttachment? attachment,
    Set<String>? memberIds,
    bool? isMuted,
    String? recoveryReason,
    bool clearRecoveryReason = false,
  }) {
    return RoomSession(
      roomId: roomId,
      sessionId: sessionId,
      localMemberId: localMemberId,
      phase: phase ?? this.phase,
      attachment: attachment ?? this.attachment,
      memberIds: memberIds ?? this.memberIds,
      isMuted: isMuted ?? this.isMuted,
      recoveryReason: clearRecoveryReason
          ? null
          : recoveryReason ?? this.recoveryReason,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is RoomSession &&
      other.roomId == roomId &&
      other.sessionId == sessionId &&
      other.localMemberId == localMemberId &&
      other.phase == phase &&
      other.attachment == attachment &&
      _setEquals(other.memberIds, memberIds) &&
      other.isMuted == isMuted &&
      other.recoveryReason == recoveryReason;

  @override
  int get hashCode => Object.hash(
    roomId,
    sessionId,
    localMemberId,
    phase,
    attachment,
    Object.hashAll(memberIds.toList()..sort()),
    isMuted,
    recoveryReason,
  );
}

bool _setEquals<T>(Set<T> a, Set<T> b) {
  if (identical(a, b)) return true;
  if (a.length != b.length) return false;
  return a.containsAll(b);
}
