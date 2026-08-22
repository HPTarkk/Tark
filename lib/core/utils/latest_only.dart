/// Tags a sequence of overlapping async calls so only the most recently
/// started one is ever treated as current — see [PreflightService]'s
/// `runBackground` for the motivating case: a remediation action's own
/// retry can still be in flight (reading stale OS state) when a later,
/// independently-triggered recheck already has the fresh answer. Without
/// this, whichever call happens to finish last decides the outcome,
/// regardless of which one actually started last.
class LatestOnly {
  int _generation = 0;

  /// Call at the start of an attempt; keep the returned token and pass it to
  /// [isCurrent] once the attempt's async work resolves.
  int start() => ++_generation;

  /// Whether [generation] is still the most recently started attempt — false
  /// once a later [start] has superseded it.
  bool isCurrent(int generation) => generation == _generation;
}
