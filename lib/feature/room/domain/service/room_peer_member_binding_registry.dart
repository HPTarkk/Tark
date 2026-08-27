import '../entity/room.dart';

/// Attachment-scoped mapping from an opaque transport peer key to a durable
/// RoomMemberId that has already been admitted by Room membership logic.
///
/// This registry does not authenticate packets or invitations. Its safety role
/// is narrower: transport discovery/capability code cannot invent a Room member
/// merely by advertising an arbitrary identifier. Callers must first establish
/// membership through the canonical Room flow, then bind the observed transport
/// peer key to that admitted member for the current attachment generation.
final class RoomPeerMemberBindingRegistry {
  RoomPeerMemberBindingRegistry({required Iterable<RoomMemberId> members})
    : _members = members.toSet();

  final Set<RoomMemberId> _members;
  final Map<String, _PeerMemberBinding> _byPeer = {};
  final Map<RoomMemberId, String> _peerByMember = {};
  int _minimumAttachmentGeneration = 0;
  bool _disposed = false;

  int get length => _byPeer.length;

  void replaceMembers(Iterable<RoomMemberId> members) {
    _ensureOpen();
    _members
      ..clear()
      ..addAll(members);
    final removedPeers = _byPeer.entries
        .where((entry) => !_members.contains(entry.value.memberId))
        .map((entry) => entry.key)
        .toList(growable: false);
    for (final peerKey in removedPeers) {
      _removePeer(peerKey);
    }
  }

  /// Binds a transport peer only when [memberId] belongs to the current Room.
  ///
  /// A peer and member are one-to-one within an attachment. A different route
  /// for an already-bound member may take over only in a strictly newer
  /// attachment generation; same-generation route changes fail closed. This
  /// makes transport replacement explicit and prevents replayed join evidence
  /// from stealing identity inside a live attachment.
  bool bind({
    required String peerKey,
    required RoomMemberId memberId,
    required int attachmentGeneration,
  }) {
    _ensureOpen();
    if (peerKey.isEmpty ||
        attachmentGeneration < _minimumAttachmentGeneration) {
      return false;
    }
    if (!_members.contains(memberId)) return false;

    final currentForPeer = _byPeer[peerKey];
    if (currentForPeer != null &&
        attachmentGeneration < currentForPeer.attachmentGeneration) {
      return false;
    }

    final currentPeerForMember = _peerByMember[memberId];
    if (currentPeerForMember != null && currentPeerForMember != peerKey) {
      final currentForMember = _byPeer[currentPeerForMember];
      if (currentForMember != null &&
          attachmentGeneration <= currentForMember.attachmentGeneration) {
        return false;
      }
      _removePeer(currentPeerForMember);
    }

    if (currentForPeer != null && currentForPeer.memberId != memberId) {
      _peerByMember.remove(currentForPeer.memberId);
    }

    _byPeer[peerKey] = _PeerMemberBinding(
      memberId: memberId,
      attachmentGeneration: attachmentGeneration,
    );
    _peerByMember[memberId] = peerKey;
    return true;
  }

  RoomMemberId? resolve(String peerKey, {required int attachmentGeneration}) {
    _ensureOpen();
    if (attachmentGeneration < _minimumAttachmentGeneration) return null;
    final binding = _byPeer[peerKey];
    if (binding == null ||
        binding.attachmentGeneration != attachmentGeneration ||
        !_members.contains(binding.memberId)) {
      return null;
    }
    return binding.memberId;
  }

  void removePeer(String peerKey) {
    _ensureOpen();
    _removePeer(peerKey);
  }

  void removeMember(RoomMemberId memberId) {
    _ensureOpen();
    _members.remove(memberId);
    final peerKey = _peerByMember.remove(memberId);
    if (peerKey != null) _byPeer.remove(peerKey);
  }

  void replaceAttachment(int attachmentGeneration) {
    _ensureOpen();
    if (attachmentGeneration < _minimumAttachmentGeneration) return;
    _minimumAttachmentGeneration = attachmentGeneration;
    final stalePeers = _byPeer.entries
        .where(
          (entry) => entry.value.attachmentGeneration < attachmentGeneration,
        )
        .map((entry) => entry.key)
        .toList(growable: false);
    for (final peerKey in stalePeers) {
      _removePeer(peerKey);
    }
  }

  void reset() {
    _ensureOpen();
    _byPeer.clear();
    _peerByMember.clear();
  }

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _byPeer.clear();
    _peerByMember.clear();
    _members.clear();
  }

  void _removePeer(String peerKey) {
    final binding = _byPeer.remove(peerKey);
    if (binding != null && _peerByMember[binding.memberId] == peerKey) {
      _peerByMember.remove(binding.memberId);
    }
  }

  void _ensureOpen() {
    if (_disposed) {
      throw StateError('RoomPeerMemberBindingRegistry is disposed');
    }
  }
}

final class _PeerMemberBinding {
  const _PeerMemberBinding({
    required this.memberId,
    required this.attachmentGeneration,
  });

  final RoomMemberId memberId;
  final int attachmentGeneration;
}
