enum HostHotspotRecoveryPhase {
  up,
  hotspotLost,
  rehosting,
  credentialsChanged,
  waitingForMembers,
  restored,
  failed,
  cancelled,
}

/// Opaque credential revision only. The actual SSID/password never enters this
/// state machine or diagnostics.
class HostHotspotRecoveryState {
  const HostHotspotRecoveryState({
    required this.phase,
    required this.attempt,
    required this.generation,
    required this.credentialRevision,
    required this.membersExpected,
    required this.membersBidirectionallyReachable,
    this.reason,
  });

  const HostHotspotRecoveryState.up({
    this.generation = 0,
    this.credentialRevision = 0,
    int membersExpected = 0,
  }) : phase = HostHotspotRecoveryPhase.up,
       attempt = 0,
       membersExpected = membersExpected,
       membersBidirectionallyReachable = membersExpected,
       reason = null;

  final HostHotspotRecoveryPhase phase;
  final int attempt;
  final int generation;
  final int credentialRevision;
  final int membersExpected;
  final int membersBidirectionallyReachable;
  final String? reason;

  bool get isLive =>
      phase == HostHotspotRecoveryPhase.up ||
      phase == HostHotspotRecoveryPhase.restored;

  bool get isRecovering =>
      phase != HostHotspotRecoveryPhase.up &&
      phase != HostHotspotRecoveryPhase.restored &&
      phase != HostHotspotRecoveryPhase.failed &&
      phase != HostHotspotRecoveryPhase.cancelled;
}

class HostHotspotRecoveryMachine {
  HostHotspotRecoveryMachine({this.maxAttempts = 4}) : assert(maxAttempts > 0);

  final int maxAttempts;
  HostHotspotRecoveryState _state = const HostHotspotRecoveryState.up();

  HostHotspotRecoveryState get state => _state;

  HostHotspotRecoveryState hotspotLost({
    required int generation,
    required int membersExpected,
    String reason = 'hotspot_lost',
  }) {
    if (_isTerminal) return _state;
    if (generation < _state.generation) return _state;
    return _set(
      HostHotspotRecoveryState(
        phase: HostHotspotRecoveryPhase.hotspotLost,
        attempt: 0,
        generation: generation,
        credentialRevision: _state.credentialRevision,
        membersExpected: membersExpected,
        membersBidirectionallyReachable: 0,
        reason: reason,
      ),
    );
  }

  HostHotspotRecoveryState beginRehost() {
    if (_isTerminal || !_state.isRecovering) return _state;
    final nextAttempt = _state.attempt + 1;
    if (nextAttempt > maxAttempts) {
      return _fail('rehost_attempts_exhausted');
    }
    return _set(
      HostHotspotRecoveryState(
        phase: HostHotspotRecoveryPhase.rehosting,
        attempt: nextAttempt,
        generation: _state.generation + 1,
        credentialRevision: _state.credentialRevision,
        membersExpected: _state.membersExpected,
        membersBidirectionallyReachable: 0,
        reason: 'rehosting',
      ),
    );
  }

  HostHotspotRecoveryState rehosted({
    required int generation,
    required int credentialRevision,
  }) {
    if (_isTerminal || generation != _state.generation) return _state;
    if (_state.phase != HostHotspotRecoveryPhase.rehosting) return _state;
    if (credentialRevision <= _state.credentialRevision) {
      return _fail('credentials_not_refreshed');
    }
    return _set(
      HostHotspotRecoveryState(
        phase: HostHotspotRecoveryPhase.credentialsChanged,
        attempt: _state.attempt,
        generation: generation,
        credentialRevision: credentialRevision,
        membersExpected: _state.membersExpected,
        membersBidirectionallyReachable: 0,
        reason: 'credentials_changed',
      ),
    );
  }

  HostHotspotRecoveryState credentialsPublished({required int generation}) {
    if (_isTerminal || generation != _state.generation) return _state;
    if (_state.phase != HostHotspotRecoveryPhase.credentialsChanged) {
      return _state;
    }
    if (_state.membersExpected == 0) return _restore();
    return _set(
      HostHotspotRecoveryState(
        phase: HostHotspotRecoveryPhase.waitingForMembers,
        attempt: _state.attempt,
        generation: generation,
        credentialRevision: _state.credentialRevision,
        membersExpected: _state.membersExpected,
        membersBidirectionallyReachable: 0,
        reason: 'waiting_for_members',
      ),
    );
  }

  /// Presence alone is not enough. Only bidirectional reachability can restore
  /// a live status after the credentials changed.
  HostHotspotRecoveryState peerEvidence({
    required int generation,
    required int bidirectionallyReachable,
  }) {
    if (_isTerminal || generation != _state.generation) return _state;
    if (_state.phase != HostHotspotRecoveryPhase.waitingForMembers) {
      return _state;
    }
    final reachable = bidirectionallyReachable.clamp(0, _state.membersExpected);
    if (reachable >= _state.membersExpected) return _restore();
    return _set(
      HostHotspotRecoveryState(
        phase: HostHotspotRecoveryPhase.waitingForMembers,
        attempt: _state.attempt,
        generation: generation,
        credentialRevision: _state.credentialRevision,
        membersExpected: _state.membersExpected,
        membersBidirectionallyReachable: reachable,
        reason: 'waiting_for_members',
      ),
    );
  }

  HostHotspotRecoveryState rehostFailed({
    required int generation,
    String reason = 'rehost_failed',
  }) {
    if (_isTerminal || generation != _state.generation) return _state;
    if (_state.attempt >= maxAttempts) return _fail(reason);
    return _set(
      HostHotspotRecoveryState(
        phase: HostHotspotRecoveryPhase.hotspotLost,
        attempt: _state.attempt,
        generation: generation,
        credentialRevision: _state.credentialRevision,
        membersExpected: _state.membersExpected,
        membersBidirectionallyReachable: 0,
        reason: reason,
      ),
    );
  }

  HostHotspotRecoveryState cancel() {
    if (_isTerminal) return _state;
    return _set(
      HostHotspotRecoveryState(
        phase: HostHotspotRecoveryPhase.cancelled,
        attempt: _state.attempt,
        generation: _state.generation,
        credentialRevision: _state.credentialRevision,
        membersExpected: _state.membersExpected,
        membersBidirectionallyReachable: 0,
        reason: 'user_cancelled',
      ),
    );
  }

  bool get _isTerminal =>
      _state.phase == HostHotspotRecoveryPhase.failed ||
      _state.phase == HostHotspotRecoveryPhase.cancelled;

  HostHotspotRecoveryState _restore() => _set(
    HostHotspotRecoveryState(
      phase: HostHotspotRecoveryPhase.restored,
      attempt: _state.attempt,
      generation: _state.generation,
      credentialRevision: _state.credentialRevision,
      membersExpected: _state.membersExpected,
      membersBidirectionallyReachable: _state.membersExpected,
      reason: 'bidirectional_reachability_restored',
    ),
  );

  HostHotspotRecoveryState _fail(String reason) => _set(
    HostHotspotRecoveryState(
      phase: HostHotspotRecoveryPhase.failed,
      attempt: _state.attempt,
      generation: _state.generation,
      credentialRevision: _state.credentialRevision,
      membersExpected: _state.membersExpected,
      membersBidirectionallyReachable: 0,
      reason: reason,
    ),
  );

  HostHotspotRecoveryState _set(HostHotspotRecoveryState next) {
    _state = next;
    return next;
  }
}
