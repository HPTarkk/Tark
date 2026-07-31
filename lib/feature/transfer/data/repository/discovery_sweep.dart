/// Paces the unicast discovery sweep so it can never outrun the socket.
///
/// The sweep exists for platforms where UDP broadcast never arrives (iOS
/// without Apple's multicast entitlement): while no peer is known, presence is
/// unicast to every host of each private /24 we sit on. Emitted all at once
/// that is ~254 datagrams per subnet — over 500 on a phone holding both a
/// hotspot and a Wi-Fi address — in a single synchronous burst.
///
/// A burst that size overruns the socket's send buffer, and everything past
/// the overrun is discarded: `send` returns 0 and the datagram never leaves.
/// Because the sweep shares its socket with the real traffic, what got
/// discarded was the broadcasts and unicasts actually carrying the session —
/// the buffer was still saturated on the next tick, so even the very first
/// broadcast of the following round was dropped.
///
/// That made the sweep self-defeating in the worst way. It runs only while no
/// peer is known, and it was itself the reason no peer could ever be heard: a
/// device went silent in one direction, permanently, and unmuting could not
/// bring it back.
///
/// So the sweep is handed out in slices, one per presence tick, walking a
/// cursor around the target list. A /24 pair is covered in a few seconds —
/// far inside any human's patience for discovery — and the socket is never
/// asked for more than it can take.
class DiscoverySweep {
  /// Probes emitted per tick. Comfortably under a default socket send buffer
  /// even alongside a tick's real traffic, and still covers a two-subnet
  /// sweep in about a dozen seconds at the 2s presence cadence.
  final int probesPerTick;

  DiscoverySweep({this.probesPerTick = 48})
    : assert(probesPerTick > 0, 'a sweep of zero probes never discovers');

  List<String> _targets = const [];
  int _cursor = 0;

  /// Addresses this sweep walks, in priority order.
  List<String> get targets => List.unmodifiable(_targets);

  /// Replaces the target list, keeping the cursor in range. Called when the
  /// set of interfaces changes, which is rare compared to ticks.
  void retarget(List<String> targets) {
    _targets = List.unmodifiable(targets);
    if (_targets.isEmpty) {
      _cursor = 0;
    } else {
      _cursor %= _targets.length;
    }
  }

  /// Back to the start — for when a peer is found and the sweep goes idle, so
  /// the next one that needs it begins at the head of the list rather than
  /// wherever the last one happened to stop.
  void reset() => _cursor = 0;

  /// The next slice to probe, at most [probesPerTick] long. Wraps around, so
  /// repeated calls eventually cover every target.
  List<String> nextSlice() {
    if (_targets.isEmpty) return const [];
    final count = probesPerTick < _targets.length
        ? probesPerTick
        : _targets.length;
    final slice = List<String>.generate(
      count,
      (i) => _targets[(_cursor + i) % _targets.length],
      growable: false,
    );
    _cursor = (_cursor + count) % _targets.length;
    return slice;
  }
}
