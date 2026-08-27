import '../entity/room.dart';
import 'room_member_transport_identity.dart';
import 'room_peer_member_binding_registry.dart';

/// Attachment-scoped challenge authority for binding an observed live transport
/// route to an already-admitted durable Room member.
///
/// The caller records only a challenge token it actually sent to [peerKey] on
/// the current attachment. The route is bound only after the peer returns a
/// valid issuer-certified member proof for that exact token, Room and session
/// epoch. Self-claimed member ids, display names, IP addresses and replayed old
/// proofs never create authority.
final class RoomMemberTransportProofBindingAuthority {
  RoomMemberTransportProofBindingAuthority({
    required this.roomId,
    required this.bindings,
    required this.expectedIssuerPublicKey,
    RoomMemberTransportIdentityCrypto? crypto,
    this.challengeFor = const Duration(seconds: 15),
    this.maxPending = 32,
  }) : _crypto = crypto ?? RoomMemberTransportIdentityCrypto(),
       assert(maxPending > 0);

  final RoomId roomId;
  final RoomPeerMemberBindingRegistry bindings;
  final List<int> expectedIssuerPublicKey;
  final RoomMemberTransportIdentityCrypto _crypto;
  final Duration challengeFor;
  final int maxPending;

  final Map<String, _PendingTransportChallenge> _pending = {};
  int _minimumAttachmentGeneration = 0;
  bool _disposed = false;

  int get pendingCount => _pending.length;

  /// Records one route-bound challenge emitted by the local transport.
  ///
  /// A route can have only one current challenge. Tokens are uint32 because the
  /// signed proof uses the same canonical range. Replacing a challenge for the
  /// same route is allowed only in the same/newer attachment generation and
  /// invalidates the previous token immediately.
  bool observeChallenge({
    required String peerKey,
    required int token,
    required int sessionEpoch,
    required int attachmentGeneration,
    required DateTime at,
  }) {
    _ensureOpen();
    if (peerKey.isEmpty ||
        !_isUint32(token) ||
        !_isUint32(sessionEpoch) ||
        attachmentGeneration < _minimumAttachmentGeneration) {
      return false;
    }

    final now = at.toUtc();
    _expire(now);
    final current = _pending[peerKey];
    if (current != null &&
        attachmentGeneration < current.attachmentGeneration) {
      return false;
    }

    _pending[peerKey] = _PendingTransportChallenge(
      token: token,
      sessionEpoch: sessionEpoch,
      attachmentGeneration: attachmentGeneration,
      observedAt: now,
    );
    _trimOldest();
    return true;
  }

  /// Verifies and consumes the exact challenge for [peerKey], then binds the
  /// observed route to the certified member for this attachment.
  ///
  /// The pending challenge is consumed after any proof attempt that reaches
  /// cryptographic verification. This makes a captured invalid/valid pair
  /// unable to race retries on the same bearer token; the transport must issue
  /// a fresh challenge for another attempt.
  Future<bool> verifyAndBind({
    required String peerKey,
    required String encodedProof,
    required int attachmentGeneration,
    required DateTime at,
  }) async {
    _ensureOpen();
    final now = at.toUtc();
    _expire(now);
    if (peerKey.isEmpty ||
        attachmentGeneration < _minimumAttachmentGeneration) {
      return false;
    }

    final pending = _pending[peerKey];
    if (pending == null ||
        pending.attachmentGeneration != attachmentGeneration) {
      return false;
    }

    RoomMemberTransportProof proof;
    try {
      proof = RoomMemberTransportProof.decode(encodedProof);
    } on FormatException {
      _pending.remove(peerKey);
      return false;
    }

    _pending.remove(peerKey);
    final verified = await _crypto.verifyProof(
      proof: proof,
      expectedRoomId: roomId,
      expectedIssuerPublicKey: expectedIssuerPublicKey,
      expectedToken: pending.token,
      expectedSessionEpoch: pending.sessionEpoch,
    );
    if (!verified) return false;

    return bindings.bind(
      peerKey: peerKey,
      memberId: proof.certificate.memberId,
      attachmentGeneration: attachmentGeneration,
    );
  }

  /// Advances the attachment floor and drops every challenge observed on an old
  /// transport. Delayed packets from a previous host/route therefore cannot
  /// bind identity after failover.
  void replaceAttachment(int attachmentGeneration) {
    _ensureOpen();
    if (attachmentGeneration < _minimumAttachmentGeneration) return;
    _minimumAttachmentGeneration = attachmentGeneration;
    _pending.removeWhere(
      (_, value) => value.attachmentGeneration < attachmentGeneration,
    );
    bindings.replaceAttachment(attachmentGeneration);
  }

  void removePeer(String peerKey) {
    _ensureOpen();
    _pending.remove(peerKey);
    bindings.removePeer(peerKey);
  }

  void reset() {
    _ensureOpen();
    _pending.clear();
    bindings.reset();
  }

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _pending.clear();
  }

  void _expire(DateTime now) {
    _pending.removeWhere(
      (_, value) => now.difference(value.observedAt) > challengeFor,
    );
  }

  void _trimOldest() {
    while (_pending.length > maxPending) {
      String? oldestKey;
      DateTime? oldestAt;
      for (final entry in _pending.entries) {
        if (oldestAt == null || entry.value.observedAt.isBefore(oldestAt)) {
          oldestKey = entry.key;
          oldestAt = entry.value.observedAt;
        }
      }
      if (oldestKey == null) return;
      _pending.remove(oldestKey);
    }
  }

  static bool _isUint32(int value) => value >= 0 && value <= 0xffffffff;

  void _ensureOpen() {
    if (_disposed) {
      throw StateError('RoomMemberTransportProofBindingAuthority is disposed');
    }
  }
}

final class _PendingTransportChallenge {
  const _PendingTransportChallenge({
    required this.token,
    required this.sessionEpoch,
    required this.attachmentGeneration,
    required this.observedAt,
  });

  final int token;
  final int sessionEpoch;
  final int attachmentGeneration;
  final DateTime observedAt;
}
