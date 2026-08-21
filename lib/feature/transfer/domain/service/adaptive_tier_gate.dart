/// Describes one transition [AdaptiveTierGate] made, for diagnostics — see
/// #32's "every tier transition is explainable from measured inputs" rule.
class TierTransition<T> {
  const TierTransition({
    required this.from,
    required this.to,
    required this.reason,
  });

  final T from;
  final T to;

  /// Short, stable, log-friendly — not user-facing copy.
  final String reason;

  @override
  String toString() => '$from -> $to ($reason)';
}

/// Generic hysteresis-gated state machine for "expensive" tier transitions —
/// sample rate, channel count, profile — the kind #32 explicitly separates
/// from bitrate/complexity/FEC tuning ([OpusTuner]/[MediaOpusTuner]), which
/// stays fast and hysteresis-free by design (see those classes' own "why
/// there is no hysteresis" docs). A tier here is anything ordered
/// worst-to-best in [tiers]; this class knows nothing about audio, Opus, or
/// the wire — [VoiceQualityController] is what gives it meaning for voice,
/// so the mechanism (this class) and the policy (thresholds, what counts as
/// "good", the reason strings) stay separate, matching the roadmap's "share
/// signal-processing code where sensible but keep product decisions
/// independent."
///
/// ## Why downgrade and upgrade are different shapes
///
/// A downgrade protects something already failing, so it should not wait out
/// a long observation window just to be safe — [downgradeEvidenceMs] is
/// meant to be tuned short relative to [upgradeCleanMs] by whoever configures
/// this (this class does not enforce the ordering itself; the policy layer
/// owns that choice). An upgrade makes things worse if it's wrong — an
/// audible profile flap plus a codec/jitter reset — so it earns the higher
/// bar: a long, unbroken run of clean evidence, not just "better than a
/// moment ago."
///
/// ## Why there is still a [minDwellMs] on top of both windows
///
/// Evidence windows alone allow a pathological sequence — link flips bad/
/// good/bad at a period just longer than each window — to transition on
/// every flip, once each window individually re-qualifies. [minDwellMs] is a
/// hard floor between any two transitions, in either direction, closing that
/// gap independently of how the windows are tuned.
///
/// ## Why the ceiling is not hysteresis-gated
///
/// [AdaptiveTierGate.advance]'s `ceilingIndex` models a *fact* (what the
/// current peer roster can even decode), not a quality judgement —
/// continuing to run above it is not "worth waiting out a window to be
/// sure," it is transmitting a format that cannot be understood. A ceiling
/// drop therefore takes effect on the very tick it's observed, bypassing
/// [minDwellMs] and both evidence windows. A ceiling *rise* gets no such
/// shortcut — it only opens headroom for the ordinary upgrade evidence path,
/// since more peers supporting a higher tier says nothing about whether the
/// current link can sustain it.
class AdaptiveTierGate<T> {
  AdaptiveTierGate({
    required this.tiers,
    required this.downgradeEvidenceMs,
    required this.upgradeCleanMs,
    required this.minDwellMs,
    int initialIndex = 0,
  }) : assert(tiers.isNotEmpty, 'AdaptiveTierGate needs at least one tier'),
       assert(downgradeEvidenceMs > 0),
       assert(upgradeCleanMs > 0),
       assert(minDwellMs >= 0),
       _index = initialIndex.clamp(0, tiers.length - 1),
       // Already "cooled down" at construction — a freshly built gate must
       // be able to transition as soon as real evidence qualifies, not wait
       // out an arbitrary startup cooldown nothing caused.
       _dwellMs = minDwellMs;

  /// Ordered worst (index 0) to best (last index).
  final List<T> tiers;

  final int downgradeEvidenceMs;
  final int upgradeCleanMs;
  final int minDwellMs;

  int _index;
  int _dwellMs;
  int _badMs = 0;
  int _cleanMs = 0;

  /// The tier this gate currently holds.
  T get tier => tiers[_index];

  /// [tier]'s position in [tiers], exposed for callers that need to compare
  /// it against an externally-computed ceiling index.
  int get tierIndex => _index;

  /// Advances the gate by [elapsedMs] of real time and returns the
  /// transition it made, or `null` if it stayed put.
  ///
  /// [conditionsSupportCurrentTier] is whether the link can sustain the tier
  /// this gate is holding *right now* — false accumulates toward a
  /// downgrade. [conditionsSupportNextTier] is whether conditions look good
  /// enough to justify the tier above the current one — true accumulates
  /// toward an upgrade; both are evaluated by the caller, since what "good
  /// enough" means is a per-stream policy decision this class deliberately
  /// has no opinion on. [ceilingIndex] is the highest index this gate may
  /// currently sit at (e.g. from capability negotiation) — see the class doc
  /// for why crossing it is immediate rather than hysteresis-gated.
  TierTransition<T>? advance({
    required bool conditionsSupportCurrentTier,
    required bool conditionsSupportNextTier,
    required int ceilingIndex,
    required int elapsedMs,
  }) {
    assert(elapsedMs >= 0);
    final clampedCeiling = ceilingIndex.clamp(0, tiers.length - 1);
    _dwellMs += elapsedMs;

    if (_index > clampedCeiling) {
      return _transitionTo(clampedCeiling, 'capability ceiling dropped');
    }

    if (conditionsSupportCurrentTier) {
      _badMs = 0;
    } else {
      _badMs += elapsedMs;
      _cleanMs = 0;
    }

    if (_index > 0 && _badMs >= downgradeEvidenceMs && _dwellMs >= minDwellMs) {
      return _transitionTo(_index - 1, 'sustained poor link');
    }

    // Upgrade evidence only accumulates when there is actually room to use
    // it — both structurally (not already at the top tier) and under the
    // current ceiling. Otherwise a link that stayed clean for a long time
    // while pinned at the ceiling would silently bank an upgrade the instant
    // the ceiling lifts, jumping tiers without ever having been *observed*
    // clean while an upgrade was even reachable.
    final hasRoomToUpgrade =
        _index < tiers.length - 1 && _index < clampedCeiling;
    if (hasRoomToUpgrade && conditionsSupportNextTier) {
      _cleanMs += elapsedMs;
    } else {
      _cleanMs = 0;
    }

    if (hasRoomToUpgrade &&
        _cleanMs >= upgradeCleanMs &&
        _dwellMs >= minDwellMs) {
      return _transitionTo(_index + 1, 'sustained clean link');
    }

    return null;
  }

  TierTransition<T> _transitionTo(int newIndex, String reason) {
    final from = tier;
    _index = newIndex;
    _badMs = 0;
    _cleanMs = 0;
    _dwellMs = 0;
    return TierTransition(from: from, to: tier, reason: reason);
  }

  /// Snaps to [index] with no transition event and a fresh cooldown — call
  /// on a session/channel reset (a new session's link has told this gate
  /// nothing yet), not as a quality judgement.
  void reset(int index) {
    _index = index.clamp(0, tiers.length - 1);
    _badMs = 0;
    _cleanMs = 0;
    _dwellMs = minDwellMs;
  }
}
