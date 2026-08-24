/// The temporary connectivity used by a live room session.
///
/// A transport attachment is deliberately not a room. Hosting a hotspot,
/// acting as a Bluetooth client, or using WebRTC is only how this particular
/// live session is connected right now. Replacing this value must never rename
/// the room, change membership, or imply ownership of the room.
enum TransportKind { wifi, hotspot, bluetooth, webrtc }

enum TransportAttachmentPhase {
  detached,
  attaching,
  attached,
  degraded,
  recovering,
  failed,
  disposed,
}

class TransportAttachment {
  const TransportAttachment({
    required this.kind,
    required this.phase,
    required this.generation,
    this.role,
    this.reason,
  });

  const TransportAttachment.detached()
    : kind = null,
      phase = TransportAttachmentPhase.detached,
      generation = 0,
      role = null,
      reason = null;

  final TransportKind? kind;
  final TransportAttachmentPhase phase;

  /// Monotonically increases whenever a replacement attachment is started.
  /// Native callbacks from an older generation are stale by construction.
  final int generation;

  /// Ephemeral transport role only, for example `host`, `joiner`, or `peer`.
  /// It is intentionally an opaque transport concern rather than a room role.
  final String? role;

  /// Privacy-safe diagnostic reason code. Never credentials, addresses, or
  /// user-provided room data.
  final String? reason;

  bool get isUsable =>
      phase == TransportAttachmentPhase.attached ||
      phase == TransportAttachmentPhase.degraded;

  bool get isRecovering => phase == TransportAttachmentPhase.recovering;

  bool get isTerminal =>
      phase == TransportAttachmentPhase.failed ||
      phase == TransportAttachmentPhase.disposed;

  TransportAttachment copyWith({
    TransportKind? kind,
    TransportAttachmentPhase? phase,
    int? generation,
    String? role,
    String? reason,
    bool clearRole = false,
    bool clearReason = false,
  }) {
    return TransportAttachment(
      kind: kind ?? this.kind,
      phase: phase ?? this.phase,
      generation: generation ?? this.generation,
      role: clearRole ? null : role ?? this.role,
      reason: clearReason ? null : reason ?? this.reason,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is TransportAttachment &&
      other.kind == kind &&
      other.phase == phase &&
      other.generation == generation &&
      other.role == role &&
      other.reason == reason;

  @override
  int get hashCode => Object.hash(kind, phase, generation, role, reason);
}
