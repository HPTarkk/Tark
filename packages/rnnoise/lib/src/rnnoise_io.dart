import 'dart:typed_data';

import 'rnnoise_ffi.dart';
import 'rnnoise_stream_ffi.dart';

abstract class RnnoiseImpl {
  int get frameSize;
  (Float32List out, double vadProbability) process(Float32List frame);
  void dispose();
}

class _RnnoiseIoImpl implements RnnoiseImpl {
  _RnnoiseIoImpl(this._ffi);

  final RnnoiseFFI _ffi;

  @override
  int get frameSize => _ffi.frameSize;

  @override
  (Float32List out, double vadProbability) process(Float32List frame) =>
      _ffi.processFrame(frame);

  @override
  void dispose() => _ffi.dispose();
}

RnnoiseImpl? tryCreateRnnoiseImpl() {
  final ffi = RnnoiseFFI.tryCreate();
  if (ffi == null) return null;
  return _RnnoiseIoImpl(ffi);
}

abstract class RnnoiseStreamImpl {
  Float64List process(List<double> samples, double strength);
  void reset();
  void dispose();
}

class _RnnoiseStreamIoImpl implements RnnoiseStreamImpl {
  _RnnoiseStreamIoImpl(this._ffi);
  final RnnoiseStreamFFI _ffi;

  @override
  Float64List process(List<double> samples, double strength) =>
      _ffi.process(samples, strength);

  @override
  void reset() => _ffi.reset();

  @override
  void dispose() => _ffi.dispose();
}

RnnoiseStreamImpl? tryCreateRnnoiseStreamImpl(int sampleRateHz) {
  final ffi = RnnoiseStreamFFI.tryCreate(sampleRateHz);
  return ffi == null ? null : _RnnoiseStreamIoImpl(ffi);
}
