import 'dart:ffi';
import 'dart:io';

/// Opaque native types — never dereferenced from Dart, only passed around.
final class DenoiseState extends Opaque {}

final class RNNModel extends Opaque {}

typedef RnnoiseGetFrameSizeNative = Int32 Function();
typedef RnnoiseGetFrameSize = int Function();

typedef RnnoiseCreateNative = Pointer<DenoiseState> Function(
  Pointer<RNNModel> model,
);
typedef RnnoiseCreate = Pointer<DenoiseState> Function(
  Pointer<RNNModel> model,
);

typedef RnnoiseDestroyNative = Void Function(Pointer<DenoiseState> st);
typedef RnnoiseDestroy = void Function(Pointer<DenoiseState> st);

typedef RnnoiseProcessFrameNative =
    Float Function(
      Pointer<DenoiseState> st,
      Pointer<Float> out,
      Pointer<Float> input,
    );
typedef RnnoiseProcessFrame =
    double Function(
      Pointer<DenoiseState> st,
      Pointer<Float> out,
      Pointer<Float> input,
    );

/// Raw symbol lookups against the native `librnnoise` built from the vendored
/// Xiph.Org sources in `packages/rnnoise/src`. See rnnoise.h for the C API
/// this mirrors 1:1.
class RnnoiseBindings {
  late final DynamicLibrary _lib;

  late final RnnoiseGetFrameSize getFrameSize;
  late final RnnoiseCreate create;
  late final RnnoiseDestroy destroy;
  late final RnnoiseProcessFrame processFrame;

  RnnoiseBindings() {
    _lib = _loadLibrary();

    getFrameSize = _lib
        .lookup<NativeFunction<RnnoiseGetFrameSizeNative>>(
          'rnnoise_get_frame_size',
        )
        .asFunction();

    create = _lib
        .lookup<NativeFunction<RnnoiseCreateNative>>('rnnoise_create')
        .asFunction();

    destroy = _lib
        .lookup<NativeFunction<RnnoiseDestroyNative>>('rnnoise_destroy')
        .asFunction();

    processFrame = _lib
        .lookup<NativeFunction<RnnoiseProcessFrameNative>>(
          'rnnoise_process_frame',
        )
        .asFunction();
  }

  static DynamicLibrary _loadLibrary() {
    if (Platform.isAndroid) {
      return DynamicLibrary.open('librnnoise.so');
    } else if (Platform.isIOS || Platform.isMacOS) {
      return DynamicLibrary.process();
    } else {
      throw UnsupportedError('rnnoise: platform not supported');
    }
  }
}
