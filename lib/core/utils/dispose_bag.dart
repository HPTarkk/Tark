import 'dart:async';

/// A small keyed registry for [StreamSubscription]s and [Timer]s, so a class
/// that re-wires the same set of resources in more than one place (initial
/// setup, a retry path, teardown) can't accidentally leave a stale one
/// running.
///
/// [register] cancels whatever was previously registered under the same key
/// before adopting the new resource — the structural version of the
/// cancel-then-reassign dance that's easy to get wrong by hand across
/// several call sites. [disposeAll] cancels and clears everything, and is
/// idempotent: a class can call it defensively on every retry/re-entry
/// without worrying whether anything is actually left to cancel.
class DisposeBag {
  final Map<String, Object> _resources = {};

  /// How many resources are currently registered. Exposed for tests; nothing
  /// in production code should need to inspect this.
  int get length => _resources.length;

  /// Registers [resource] under [key], cancelling and discarding whatever was
  /// registered there before. Returns [resource] so a call site can register
  /// and assign a field in the same expression, e.g.
  /// `_frameSub = _resources.register('frame', stream.listen(...));`.
  ///
  /// The replaced resource's cancel is fire-and-forget rather than awaited —
  /// `register` has to stay synchronous for that assignment idiom to work.
  /// Call [cancel] or [disposeAll] first when the old resource's cancel needs
  /// to be awaited before the new one starts.
  T register<T extends Object>(String key, T resource) {
    assert(
      resource is StreamSubscription || resource is Timer,
      'DisposeBag only accepts StreamSubscription or Timer, got ${resource.runtimeType}',
    );
    final previous = _resources.remove(key);
    if (previous != null) unawaited(_cancel(previous));
    _resources[key] = resource;
    return resource;
  }

  /// Cancels and removes [key]'s resource, awaiting the cancel. A no-op if
  /// nothing is registered there.
  Future<void> cancel(String key) async {
    final resource = _resources.remove(key);
    if (resource != null) await _cancel(resource);
  }

  /// Cancels and removes every registered resource, awaiting each one.
  /// Idempotent — a second call finds nothing left and returns immediately.
  Future<void> disposeAll() async {
    final resources = _resources.values.toList();
    _resources.clear();
    for (final resource in resources) {
      await _cancel(resource);
    }
  }

  static Future<void> _cancel(Object resource) async {
    if (resource is StreamSubscription) {
      await resource.cancel();
    } else if (resource is Timer) {
      resource.cancel();
    }
  }
}
