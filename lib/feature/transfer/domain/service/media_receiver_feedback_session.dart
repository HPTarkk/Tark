import '../../../audio/domain/media_adaptation_controller.dart';
import '../entity/media_receiver_feedback.dart';
import 'media_receiver_adaptation_runtime.dart';

/// Session-scoped receiver-feedback coordinator used by the existing Wi-Fi
/// heartbeat plumbing without adding another timer or growing the repository.
///
/// `WakiPacketCodec` stages decoded Pong feedback, while `PeerPingTracker`
/// admits it only after the token matches a ping that this process actually
/// sent. Media quality reads the latest deterministic room-floor decision on
/// the same heartbeat cadence. Addresses are only in-memory correlation keys;
/// they are never logged or persisted.
final class MediaReceiverFeedbackSession {
  MediaReceiverFeedbackSession._();

  static final MediaReceiverFeedbackSession shared =
      MediaReceiverFeedbackSession._();

  static const _peerFreshFor = Duration(seconds: 8);

  final MediaReceiverAdaptationRuntime _adaptation =
      MediaReceiverAdaptationRuntime.standard();
  final Map<String, DateTime> _lastPingAt = {};
  final Map<_PendingKey, _PendingFeedback> _pending = {};

  MediaAdaptationDecision _decision = const MediaAdaptationDecision(
    tier: MediaAdaptationTier.unconfirmed,
    reason: MediaAdaptationReason.feedbackUnconfirmed,
    targetBitrateKbps: 48,
    targetChannels: 1,
  );

  MediaAdaptationDecision get decision => _decision;

  void notePing(String address, DateTime at) {
    _lastPingAt[address] = at;
  }

  /// Holds decoded feedback until [confirmMatchedPong] proves it corresponds
  /// to one of our own outstanding pings. Unsolicited or stale Pong evidence
  /// therefore cannot promote/degrade media.
  void stagePong({
    required String address,
    required String peerId,
    required int token,
    required MediaReceiverFeedback? feedback,
  }) {
    if (feedback == null) return;
    _pending[_PendingKey(address, token)] = _PendingFeedback(peerId, feedback);
    if (_pending.length > 64) {
      _pending.remove(_pending.keys.first);
    }
  }

  void confirmMatchedPong(String address, int token, DateTime at) {
    final pending = _pending.remove(_PendingKey(address, token));
    if (pending == null) return;
    // Address is the liveness key because PeerPingTracker owns exactly that
    // route. The stable device id is deliberately retained only as metadata
    // inside the pending value so a future diagnostics surface can correlate
    // without ever persisting the address.
    _adaptation.observePeer(address, pending.feedback, at);
  }

  MediaAdaptationDecision evaluate(DateTime now, int elapsedMs) {
    final current = <String>[];
    for (final entry in _lastPingAt.entries.toList(growable: false)) {
      if (now.difference(entry.value) <= _peerFreshFor) {
        current.add(entry.key);
      } else {
        _lastPingAt.remove(entry.key);
        _adaptation.removePeer(entry.key);
      }
    }
    _decision = _adaptation.evaluate(
      peerIds: current,
      now: now,
      elapsedMs: elapsedMs,
    );
    return _decision;
  }

  void forget(String address) {
    _lastPingAt.remove(address);
    _adaptation.removePeer(address);
    _pending.removeWhere((key, _) => key.address == address);
  }

  void reset() {
    _lastPingAt.clear();
    _pending.clear();
    _adaptation.reset();
    _decision = const MediaAdaptationDecision(
      tier: MediaAdaptationTier.unconfirmed,
      reason: MediaAdaptationReason.feedbackUnconfirmed,
      targetBitrateKbps: 48,
      targetChannels: 1,
    );
  }
}

final class _PendingKey {
  const _PendingKey(this.address, this.token);

  final String address;
  final int token;

  @override
  bool operator ==(Object other) =>
      other is _PendingKey && other.address == address && other.token == token;

  @override
  int get hashCode => Object.hash(address, token);
}

final class _PendingFeedback {
  const _PendingFeedback(this.peerId, this.feedback);

  final String peerId;
  final MediaReceiverFeedback feedback;
}
