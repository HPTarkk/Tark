import 'dart:typed_data';

/// Growable ring-buffer FIFO of unboxed doubles for the audio hot path.
///
/// The mic/playback pipeline moves tens of thousands of samples per second
/// on the UI isolate. Plain growable `List<double>`s and `Queue<double>`s
/// box every stored double and `removeRange(0, n)` shifts the remainder —
/// together that's constant garbage and O(n) churn at audio rate, which
/// keeps the GC busy enough to cause visible UI pauses. This keeps samples
/// in a Float64List ring instead: no boxing, no shifting, amortized O(1)
/// per sample.
class Float64Fifo {
  Float64Fifo([int initialCapacity = 1024])
    : _buf = Float64List(_nextPow2(initialCapacity));

  Float64List _buf;
  int _head = 0;
  int _length = 0;

  // Power-of-two capacity so wrapping is a mask, not a modulo.
  static int _nextPow2(int n) {
    var c = 2;
    while (c < n) {
      c <<= 1;
    }
    return c;
  }

  int get length => _length;
  bool get isEmpty => _length == 0;
  bool get isNotEmpty => _length != 0;

  double operator [](int index) {
    assert(index >= 0 && index < _length);
    return _buf[(_head + index) & (_buf.length - 1)];
  }

  void _ensureRoom(int incoming) {
    final needed = _length + incoming;
    if (needed <= _buf.length) return;
    var cap = _buf.length;
    while (cap < needed) {
      cap <<= 1;
    }
    final next = Float64List(cap);
    final mask = _buf.length - 1;
    for (var i = 0; i < _length; i++) {
      next[i] = _buf[(_head + i) & mask];
    }
    _buf = next;
    _head = 0;
  }

  void addAll(List<double> samples) {
    _ensureRoom(samples.length);
    final mask = _buf.length - 1;
    var w = (_head + _length) & mask;
    for (var i = 0; i < samples.length; i++) {
      _buf[w] = samples[i];
      w = (w + 1) & mask;
    }
    _length += samples.length;
  }

  void addZeros(int count) {
    _ensureRoom(count);
    final mask = _buf.length - 1;
    var w = (_head + _length) & mask;
    for (var i = 0; i < count; i++) {
      _buf[w] = 0.0;
      w = (w + 1) & mask;
    }
    _length += count;
  }

  /// Removes the first [count] samples and returns them as a fresh list.
  Float64List takeFirst(int count) {
    assert(count >= 0 && count <= _length);
    final out = Float64List(count);
    final mask = _buf.length - 1;
    for (var i = 0; i < count; i++) {
      out[i] = _buf[(_head + i) & mask];
    }
    _head = (_head + count) & mask;
    _length -= count;
    return out;
  }

  /// Drops the first [count] samples without copying them anywhere.
  void discardFirst(int count) {
    assert(count >= 0 && count <= _length);
    _head = (_head + count) & (_buf.length - 1);
    _length -= count;
  }

  void clear() {
    _head = 0;
    _length = 0;
  }
}
