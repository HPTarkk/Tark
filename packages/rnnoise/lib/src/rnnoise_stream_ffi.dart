import 'dart:ffi';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

import 'rnnoise_bindings.dart';

/// Owns one native stream and two reusable buffers at the FFI boundary.
class RnnoiseStreamFFI {
  RnnoiseStreamFFI._(this._bindings, this._handle);

  static RnnoiseStreamFFI? tryCreate(int sampleRateHz) {
    if (sampleRateHz <= 0) return null;
    try {
      final bindings = RnnoiseBindings().tryStreamBindings();
      if (bindings == null) return null;
      final handle = bindings.create(sampleRateHz);
      if (handle == nullptr) return null;
      return RnnoiseStreamFFI._(bindings, handle);
    } catch (_) {
      return null;
    }
  }

  final RnnoiseStreamBindings _bindings;
  Pointer<Void> _handle;
  Pointer<Double> _input = nullptr;
  Pointer<Double> _output = nullptr;
  int _capacity = 0;

  void _checkAlive() {
    if (_handle == nullptr) throw StateError('RNNoise stream is disposed');
  }

  void _ensureCapacity(int count) {
    if (count <= _capacity) return;
    var capacity = _capacity == 0 ? 1024 : _capacity;
    while (capacity < count) {
      capacity *= 2;
    }
    final input = malloc<Double>(capacity);
    Pointer<Double> output = nullptr;
    try {
      output = malloc<Double>(capacity);
    } catch (_) {
      malloc.free(input);
      rethrow;
    }
    malloc.free(_input);
    malloc.free(_output);
    _input = input;
    _output = output;
    _capacity = capacity;
  }

  Float64List process(List<double> samples, double strength) {
    _checkAlive();
    if (!strength.isFinite) {
      throw ArgumentError.value(strength, 'strength', 'must be finite');
    }
    _ensureCapacity(samples.length);
    if (samples.isNotEmpty) {
      _input.asTypedList(samples.length).setAll(0, samples);
    }
    final result = _bindings.process(
      _handle,
      _input,
      _output,
      samples.length,
      strength,
    );
    if (result != samples.length) {
      throw StateError(
          'RNNoise stream failed to process ${samples.length} samples');
    }
    if (samples.isEmpty) return Float64List(0);
    return Float64List.fromList(_output.asTypedList(samples.length));
  }

  void reset() {
    _checkAlive();
    if (_bindings.reset(_handle) != 0) {
      throw StateError('RNNoise stream failed to reset');
    }
  }

  void dispose() {
    if (_handle == nullptr) return;
    _bindings.destroy(_handle);
    _handle = nullptr;
    malloc.free(_input);
    malloc.free(_output);
    _input = nullptr;
    _output = nullptr;
    _capacity = 0;
  }
}
