import 'dart:async';
import 'dart:collection';

/// Two-lane bounded write scheduler for a transport with one shared, ordered
/// write pipe — Bluetooth's RFCOMM/BLE link, where a queued write genuinely
/// blocks whatever comes after it (unlike WiFi's independent UDP sends or a
/// WebRTC data channel's own outbound queue, neither of which share a
/// blocking pipe between packet types). See #30's roadmap wording: "a simple
/// bounded priority scheduler beats a general-purpose queue framework" —
/// this is that scheduler, and nothing more general than it needs to be.
///
/// Voice/presence/control always drain before any pending media write, and
/// the media lane is bounded: once [maxQueuedLowPriority] is reached, the
/// *oldest* queued write is dropped rather than letting write latency grow
/// without bound — a stale media frame is worth less than the airtime it
/// would cost to send it late, and a backed-up low-priority lane must never
/// be able to delay the next high-priority write behind it.
class PriorityWriteScheduler<T> {
  PriorityWriteScheduler({
    required Future<void> Function(T payload) write,
    this.maxQueuedLowPriority = 5,
  }) : _write = write;

  final Future<void> Function(T payload) _write;

  /// Bound on the low-priority lane. Small on purpose: this is airtime, not
  /// memory — a deep queue here is exactly the accumulating-latency failure
  /// mode #30 exists to prevent, just moved from the network to this queue.
  final int maxQueuedLowPriority;

  final Queue<_QueuedWrite<T>> _highPriority = Queue();
  final Queue<T> _lowPriority = Queue();
  bool _pumping = false;

  /// How many low-priority writes have been dropped for arriving behind a
  /// full queue — the media analog of `MediaFrameScheduler.dropouts`, at the
  /// transport's own write pipe rather than the send-side cushion.
  int _lowPriorityDrops = 0;
  int get lowPriorityDrops => _lowPriorityDrops;

  /// Whether anything is currently queued or in flight — for diagnostics/
  /// tests, not for callers to branch on (queueing is always safe to call).
  bool get isIdle => !_pumping && _highPriority.isEmpty && _lowPriority.isEmpty;

  /// Enqueues [payload] ahead of any pending low-priority write, and
  /// completes once it has actually been written (or the underlying write
  /// throws) — the same contract a direct `await write(payload)` call had,
  /// so callers (voice, presence, control) don't have to change how they
  /// treat the result.
  Future<void> writeHighPriority(T payload) {
    final completer = Completer<void>();
    _highPriority.add(_QueuedWrite(payload, completer));
    unawaited(_pump());
    return completer.future;
  }

  /// Enqueues [payload] behind any pending/future high-priority write.
  /// Fire-and-forget by design: media has nothing useful to do with a
  /// completion signal (see `MediaFrameScheduler`, which already discards
  /// its `sendMedia` result), and awaiting one here would reintroduce
  /// exactly the "queued behind a slow write" problem this class exists to
  /// avoid for the caller. Drops the oldest queued write once
  /// [maxQueuedLowPriority] is reached.
  void writeLowPriority(T payload) {
    _lowPriority.add(payload);
    while (_lowPriority.length > maxQueuedLowPriority) {
      _lowPriority.removeFirst();
      _lowPriorityDrops++;
    }
    unawaited(_pump());
  }

  Future<void> _pump() async {
    if (_pumping) return;
    _pumping = true;
    try {
      while (_highPriority.isNotEmpty || _lowPriority.isNotEmpty) {
        // Re-checked every loop, not cached: a high-priority write queued
        // while a low-priority one is already in flight must be the very
        // next write once that one completes, not wait for the rest of the
        // low-priority lane to drain first.
        if (_highPriority.isNotEmpty) {
          final item = _highPriority.removeFirst();
          try {
            await _write(item.payload);
            item.completer.complete();
          } catch (e, st) {
            item.completer.completeError(e, st);
          }
        } else {
          final payload = _lowPriority.removeFirst();
          try {
            await _write(payload);
          } catch (_) {
            // Best-effort: writeLowPriority callers don't await, so there is
            // nobody here to report a failure to. The transport's own
            // reconnect/health machinery is what notices a dead link.
          }
        }
      }
    } finally {
      _pumping = false;
    }
  }

  /// Drops every pending write without sending it — call on disconnect/reset
  /// so a stale queue from the session that just ended doesn't bleed writes
  /// into the next one. Any high-priority caller still awaiting one of the
  /// dropped writes is completed with an error rather than left hanging.
  void clear() {
    for (final item in _highPriority) {
      item.completer.completeError(StateError('write scheduler cleared'));
    }
    _highPriority.clear();
    _lowPriority.clear();
  }
}

class _QueuedWrite<T> {
  _QueuedWrite(this.payload, this.completer);
  final T payload;
  final Completer<void> completer;
}
