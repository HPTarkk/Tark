import '../entity/room.dart';
import 'room_invite_join_exchange.dart';
import 'room_peer_member_binding_registry.dart';

/// Attachment-scoped authority that correlates a transport route observed by
/// the join carrier with the member identity returned by the verified invite
/// acceptance flow.
///
/// The joining device never supplies the binding. A caller may record only the
/// opaque peer key it actually observed while carrying a concrete join request.
/// That peer becomes eligible for Room attribution only after the issuer returns
/// an accepted response for the exact request and current Room.
///
/// This deliberately does not authenticate arbitrary live packets, IPs, display
/// names, channels or self-claimed member ids. It is the narrow bridge between
/// the already-authorized join transaction and the attachment-scoped
/// [RoomPeerMemberBindingRegistry].
final class RoomJoinPeerBindingAuthority {
  RoomJoinPeerBindingAuthority({
    required this.roomId,
    required this.bindings,
    this.pendingFor = const Duration(seconds: 30),
    this.maxPending = 32,
  }) : assert(maxPending > 0);

  final RoomId roomId;
  final RoomPeerMemberBindingRegistry bindings;
  final Duration pendingFor;
  final int maxPending;

  final Map<String, _PendingJoinPeer> _pending = {};
  final Map<String, _ConsumedJoinRequest> _consumed = {};
  int _minimumAttachmentGeneration = 0;
  bool _disposed = false;

  int get pendingCount => _pending.length;

  /// Records transport evidence for a request received on the current
  /// attachment. The first observed route for a request is sticky within an
  /// attachment generation: replaying the same bearer request from another
  /// route cannot steal the later accepted binding. Accepted request ids retain
  /// a short bounded replay tombstone so a second route cannot resurrect the
  /// request after its pending entry has been consumed.
  ///
  /// A genuinely newer attachment generation may establish fresh route
  /// evidence. Once transport replacement advances the generation floor,
  /// delayed older callbacks fail closed even if they arrive as apparently-new
  /// requests.
  bool observeRequest({
    required String requestId,
    required String peerKey,
    required int attachmentGeneration,
    required DateTime at,
  }) {
    _ensureOpen();
    if (!_validRequestId(requestId) ||
        peerKey.isEmpty ||
        attachmentGeneration < _minimumAttachmentGeneration) {
      return false;
    }

    final now = at.toUtc();
    _expire(now);
    final consumed = _consumed[requestId];
    if (consumed != null &&
        consumed.attachmentGeneration == attachmentGeneration) {
      return false;
    }

    final current = _pending[requestId];
    if (current != null) {
      if (attachmentGeneration < current.attachmentGeneration) return false;
      if (attachmentGeneration == current.attachmentGeneration &&
          peerKey != current.peerKey) {
        return false;
      }
    }

    _pending[requestId] = _PendingJoinPeer(
      peerKey: peerKey,
      attachmentGeneration: attachmentGeneration,
      observedAt: now,
    );
    _trimOldest();
    return true;
  }

  /// Consumes one correlated accepted response and binds the route to the
  /// already-admitted durable member. Rejected/malformed/cross-Room/stale
  /// responses consume no authority and cannot create a binding.
  bool bindAcceptedResponse({
    required RoomInviteJoinResponse response,
    required int attachmentGeneration,
    required DateTime at,
  }) {
    _ensureOpen();
    final now = at.toUtc();
    _expire(now);
    if (attachmentGeneration < _minimumAttachmentGeneration ||
        response.status != RoomInviteJoinResponseStatus.accepted ||
        response.roomId != roomId ||
        response.memberId == null ||
        _consumed.containsKey(response.requestId)) {
      return false;
    }

    final pending = _pending[response.requestId];
    if (pending == null ||
        pending.attachmentGeneration != attachmentGeneration) {
      return false;
    }

    final bound = bindings.bind(
      peerKey: pending.peerKey,
      memberId: response.memberId!,
      attachmentGeneration: attachmentGeneration,
    );
    if (bound) {
      _pending.remove(response.requestId);
      _consumed[response.requestId] = _ConsumedJoinRequest(
        attachmentGeneration: attachmentGeneration,
        consumedAt: now,
      );
      _trimConsumedOldest();
    }
    return bound;
  }

  /// A transport replacement invalidates every earlier observed route and its
  /// replay tombstones. The same request may therefore be correlated again only
  /// when it is genuinely observed on the replacement attachment.
  void replaceAttachment(int attachmentGeneration) {
    _ensureOpen();
    if (attachmentGeneration < _minimumAttachmentGeneration) return;
    _minimumAttachmentGeneration = attachmentGeneration;
    _pending.removeWhere(
      (_, value) => value.attachmentGeneration < attachmentGeneration,
    );
    _consumed.removeWhere(
      (_, value) => value.attachmentGeneration < attachmentGeneration,
    );
    bindings.replaceAttachment(attachmentGeneration);
  }

  void reset() {
    _ensureOpen();
    _pending.clear();
    _consumed.clear();
    bindings.reset();
  }

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _pending.clear();
    _consumed.clear();
  }

  void _expire(DateTime now) {
    _pending.removeWhere(
      (_, value) => now.difference(value.observedAt) > pendingFor,
    );
    _consumed.removeWhere(
      (_, value) => now.difference(value.consumedAt) > pendingFor,
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

  void _trimConsumedOldest() {
    while (_consumed.length > maxPending) {
      String? oldestKey;
      DateTime? oldestAt;
      for (final entry in _consumed.entries) {
        if (oldestAt == null || entry.value.consumedAt.isBefore(oldestAt)) {
          oldestKey = entry.key;
          oldestAt = entry.value.consumedAt;
        }
      }
      if (oldestKey == null) return;
      _consumed.remove(oldestKey);
    }
  }

  static bool _validRequestId(String value) =>
      RegExp(r'^[0-9a-f]{32}$').hasMatch(value);

  void _ensureOpen() {
    if (_disposed) throw StateError('RoomJoinPeerBindingAuthority is disposed');
  }
}

final class _PendingJoinPeer {
  const _PendingJoinPeer({
    required this.peerKey,
    required this.attachmentGeneration,
    required this.observedAt,
  });

  final String peerKey;
  final int attachmentGeneration;
  final DateTime observedAt;
}

final class _ConsumedJoinRequest {
  const _ConsumedJoinRequest({
    required this.attachmentGeneration,
    required this.consumedAt,
  });

  final int attachmentGeneration;
  final DateTime consumedAt;
}
