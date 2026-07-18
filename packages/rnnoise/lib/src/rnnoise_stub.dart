import 'dart:typed_data';

/// Web (and any platform without dart:io) build: RNNoise's native library is
/// never compiled in here, so this always reports unavailable — callers
/// fall back to a pure-Dart suppressor.
abstract class RnnoiseImpl {
  int get frameSize;
  (Float32List out, double vadProbability) process(Float32List frame);
  void dispose();
}

RnnoiseImpl? tryCreateRnnoiseImpl() => null;
