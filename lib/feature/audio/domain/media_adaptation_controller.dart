import 'media_receive_buffer.dart';

enum MediaAdaptationTier {
  /// Bidirectional receiver health is not confirmed yet.
  unconfirmed,

  /// Truthful mono / lower bitrate floor for uncertain or recovering links.
  conservative,

  /// Stable confirmed link with some headroom, but not enough evidence for max.
  balanced,

  /// Maximum beta media tier, reached only after sustained clean evidence.
  high,

  /// Media is paused first so voice/control can recover.
  suspended,
}

enum MediaAdaptationReason {
  feedbackUnconfirmed,
  confirmedClean,
  sustainedCleanUpgrade,
  receiverDistress,
  severeReceiverDistress,
  voiceProtection,
  recoveryProbe,
  dwellHold,
}

class MediaAdaptationDecision {
  const MediaAdaptationDecision({
    required this.tier,
    required this.reason,
    required this.targetBitrateKbps,
    required this.targetChannels,
  });

  final MediaAdaptationTier tier;
  final MediaAdaptationReason reason;
  final int targetBitrateKbps;
  final int targetChannels;

  bool get shouldTransmit => tier != MediaAdaptationTier.suspended;
}

class MediaReceiverWindow {
  const MediaReceiverWindow({
    required this.health,
    required this.bidirectionalConfirmed,
  });

  final MediaReceiveHealth health;
  final bool bidirectionalConfirmed;

  bool get distressed => health.isDistressed;

  bool get severeDistress =>
      health.overflowDrops > 0 ||
      health.resyncs > 0 ||
      health.outputStarvations >= 2 ||
      health.underruns >= 2 ||
      health.staleDrops >= 3;
}

/// Deterministic Shared Music quality policy driven by receiver evidence.
///
/// The beta policy intentionally uses a stable room floor: one persistently
/// struggling receiver can lower the shared media tier, but brief single-window
/// spikes cannot flap the whole room. Media degrades before voice/control.
class MediaAdaptationController {
  MediaAdaptationController({
    this.distressWindowsToDegrade = 2,
    this.cleanWindowsToUpgrade = 5,
    this.minimumUpgradeDwellMs = 10000,
    this.suspensionProbeDwellMs = 4000,
  }) : assert(distressWindowsToDegrade > 0),
       assert(cleanWindowsToUpgrade > 0),
       assert(minimumUpgradeDwellMs >= 0),
       assert(suspensionProbeDwellMs >= 0);

  final int distressWindowsToDegrade;
  final int cleanWindowsToUpgrade;
  final int minimumUpgradeDwellMs;
  final int suspensionProbeDwellMs;

  MediaAdaptationTier _tier = MediaAdaptationTier.unconfirmed;
  int _distressWindows = 0;
  int _cleanWindows = 0;
  int _elapsedSinceChangeMs = 0;

  MediaAdaptationTier get tier => _tier;

  MediaAdaptationDecision observe({
    required List<MediaReceiverWindow> receivers,
    required int elapsedMs,
    bool voiceImpaired = false,
  }) {
    if (elapsedMs > 0) _elapsedSinceChangeMs += elapsedMs;

    if (voiceImpaired) {
      _distressWindows = 0;
      _cleanWindows = 0;
      _transition(MediaAdaptationTier.suspended);
      return _decision(MediaAdaptationReason.voiceProtection);
    }

    if (receivers.isEmpty ||
        receivers.any((receiver) => !receiver.bidirectionalConfirmed)) {
      _distressWindows = 0;
      _cleanWindows = 0;
      if (_tier != MediaAdaptationTier.suspended) {
        _transition(MediaAdaptationTier.unconfirmed);
      }
      return _decision(MediaAdaptationReason.feedbackUnconfirmed);
    }

    final hasSevereDistress = receivers.any(
      (receiver) => receiver.severeDistress,
    );
    if (hasSevereDistress) {
      _distressWindows = 0;
      _cleanWindows = 0;
      _transition(MediaAdaptationTier.suspended);
      return _decision(MediaAdaptationReason.severeReceiverDistress);
    }

    final hasDistress = receivers.any((receiver) => receiver.distressed);
    if (hasDistress) {
      _cleanWindows = 0;
      _distressWindows++;
      if (_distressWindows >= distressWindowsToDegrade) {
        _distressWindows = 0;
        _transition(_degradedTier(_tier));
        return _decision(MediaAdaptationReason.receiverDistress);
      }
      return _decision(MediaAdaptationReason.dwellHold);
    }

    _distressWindows = 0;
    _cleanWindows++;

    if (_tier == MediaAdaptationTier.suspended) {
      if (_elapsedSinceChangeMs < suspensionProbeDwellMs) {
        return _decision(MediaAdaptationReason.dwellHold);
      }
      _cleanWindows = 0;
      _transition(MediaAdaptationTier.conservative);
      return _decision(MediaAdaptationReason.recoveryProbe);
    }

    if (_tier == MediaAdaptationTier.unconfirmed) {
      _cleanWindows = 0;
      _transition(MediaAdaptationTier.conservative);
      return _decision(MediaAdaptationReason.confirmedClean);
    }

    if (_cleanWindows < cleanWindowsToUpgrade ||
        _elapsedSinceChangeMs < minimumUpgradeDwellMs) {
      return _decision(MediaAdaptationReason.dwellHold);
    }

    final upgraded = _upgradedTier(_tier);
    if (upgraded == _tier) {
      _cleanWindows = 0;
      return _decision(MediaAdaptationReason.confirmedClean);
    }

    _cleanWindows = 0;
    _transition(upgraded);
    return _decision(MediaAdaptationReason.sustainedCleanUpgrade);
  }

  void reset() {
    _tier = MediaAdaptationTier.unconfirmed;
    _distressWindows = 0;
    _cleanWindows = 0;
    _elapsedSinceChangeMs = 0;
  }

  void _transition(MediaAdaptationTier next) {
    if (next == _tier) return;
    _tier = next;
    _elapsedSinceChangeMs = 0;
  }

  static MediaAdaptationTier _degradedTier(MediaAdaptationTier current) =>
      switch (current) {
        MediaAdaptationTier.high => MediaAdaptationTier.balanced,
        MediaAdaptationTier.balanced => MediaAdaptationTier.conservative,
        MediaAdaptationTier.conservative || MediaAdaptationTier.unconfirmed =>
          MediaAdaptationTier.conservative,
        MediaAdaptationTier.suspended => MediaAdaptationTier.suspended,
      };

  static MediaAdaptationTier _upgradedTier(MediaAdaptationTier current) =>
      switch (current) {
        MediaAdaptationTier.unconfirmed => MediaAdaptationTier.conservative,
        MediaAdaptationTier.conservative => MediaAdaptationTier.balanced,
        MediaAdaptationTier.balanced => MediaAdaptationTier.high,
        MediaAdaptationTier.high => MediaAdaptationTier.high,
        MediaAdaptationTier.suspended => MediaAdaptationTier.conservative,
      };

  MediaAdaptationDecision _decision(MediaAdaptationReason reason) =>
      switch (_tier) {
        MediaAdaptationTier.unconfirmed => MediaAdaptationDecision(
          tier: _tier,
          reason: reason,
          targetBitrateKbps: 48,
          targetChannels: 1,
        ),
        MediaAdaptationTier.conservative => MediaAdaptationDecision(
          tier: _tier,
          reason: reason,
          targetBitrateKbps: 48,
          targetChannels: 1,
        ),
        MediaAdaptationTier.balanced => MediaAdaptationDecision(
          tier: _tier,
          reason: reason,
          targetBitrateKbps: 64,
          targetChannels: 1,
        ),
        MediaAdaptationTier.high => MediaAdaptationDecision(
          tier: _tier,
          reason: reason,
          targetBitrateKbps: 96,
          targetChannels: 2,
        ),
        MediaAdaptationTier.suspended => MediaAdaptationDecision(
          tier: _tier,
          reason: reason,
          targetBitrateKbps: 0,
          targetChannels: 0,
        ),
      };
}
