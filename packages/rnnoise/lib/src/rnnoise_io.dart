import 'dart:typed_data';

import 'rnnoise_ffi.dart';

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
