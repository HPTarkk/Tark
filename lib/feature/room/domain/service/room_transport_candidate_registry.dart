import '../entity/room.dart';
import 'room_transport_planner.dart';

/// One verified member capability observation used to build a deterministic
/// room-wide transport plan.
///
/// The registry deliberately owns no transport discovery, timers, sockets, or
/// packet parsing. Callers may feed it only after mapping an advertisement to a
/// durable [RoomMemberId]. Older/unknown peers are therefore absent rather than
/// fabricated as capable.
final class RoomTransportCandidateObservation {
  const RoomTransportCandidateObservation({
    required this.candidate,
    required this.observedAt,
    required this.attachmentGeneration,
  }) : assert(attachmentGeneration >= 0);

  final RoomTransportCandidate candidate;
  final DateTime observedAt;
  final int attachmentGeneration;
}

/// Bounded, generation-aware source of planner candidates for #48/#51.
///
/// A transport replacement advances [attachmentGeneration]. Observations from
/// an older attachment can never overwrite the current generation, and stale
/// capability evidence ages out instead of allowing a vanished rider to win a
/// later host election.
final class RoomTransportCandidateRegistry {
  RoomTransportCandidateRegistry({
    this.freshFor = const Duration(seconds: 10),
    this.maxCandidates = 12,
  }) : assert(freshFor > Duration.zero),
       assert(maxCandidates > 0);

  final Duration freshFor;
  final int maxCandidates;

  final Map<RoomMemberId, RoomTransportCandidateObservation> _observations = {};
  bool _disposed = false;

  int get length => _observations.length;

  void observe(
    RoomTransportCandidate candidate, {
    required DateTime at,
    required int attachmentGeneration,
  }) {
    _ensureOpen();
    final current = _observations[candidate.memberId];
    if (current != null &&
        attachmentGeneration < current.attachmentGeneration) {
      return;
    }

    if (current == null && _observations.length >= maxCandidates) {
      _evictOldest();
    }
    _observations[candidate.memberId] = RoomTransportCandidateObservation(
      candidate: candidate,
      observedAt: at,
      attachmentGeneration: attachmentGeneration,
    );
  }

  void remove(RoomMemberId memberId) {
    _ensureOpen();
    _observations.remove(memberId);
  }

  /// Drops observations from previous attachments. A replacement transport has
  /// to re-establish capability evidence before automatic host election can
  /// trust a peer again.
  void replaceAttachment(int attachmentGeneration) {
    _ensureOpen();
    _observations.removeWhere(
      (_, value) => value.attachmentGeneration < attachmentGeneration,
    );
  }

  /// Returns only fresh observations for the requested attachment generation,
  /// in stable member-id order so identical evidence yields identical planner
  /// input on every participant.
  List<RoomTransportCandidate> snapshot({
    required DateTime now,
    required int attachmentGeneration,
  }) {
    _ensureOpen();
    _observations.removeWhere(
      (_, value) => now.difference(value.observedAt) > freshFor,
    );
    final candidates =
        _observations.values
            .where(
              (value) => value.attachmentGeneration == attachmentGeneration,
            )
            .map((value) => value.candidate)
            .toList(growable: false)
          ..sort((a, b) => a.memberId.value.compareTo(b.memberId.value));
    return List.unmodifiable(candidates);
  }

  void reset() {
    _ensureOpen();
    _observations.clear();
  }

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _observations.clear();
  }

  void _evictOldest() {
    RoomMemberId? oldestId;
    RoomTransportCandidateObservation? oldest;
    for (final entry in _observations.entries) {
      final currentOldest = oldest;
      if (currentOldest == null ||
          entry.value.observedAt.isBefore(currentOldest.observedAt) ||
          (entry.value.observedAt == currentOldest.observedAt &&
              entry.key.value.compareTo(oldestId!.value) < 0)) {
        oldestId = entry.key;
        oldest = entry.value;
      }
    }
    if (oldestId != null) _observations.remove(oldestId);
  }

  void _ensureOpen() {
    if (_disposed) {
      throw StateError('RoomTransportCandidateRegistry is disposed');
    }
  }
}
