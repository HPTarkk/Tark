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

typedef RnnoiseProcessFrameNative = Float Function(
  Pointer<DenoiseState> st,
  Pointer<Float> out,
  Pointer<Float> input,
);
typedef RnnoiseProcessFrame = double Function(
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

  RnnoiseBindings({DynamicLibrary? library}) {
    _lib = library ?? _loadLibrary();

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
    // Host parity tests compile the exact mobile sources into a shared library.
    // Normal application builds continue to use their bundled platform library.
    final libraryPath = Platform.environment['RNNOISE_LIBRARY_PATH'];
    if (libraryPath != null && libraryPath.isNotEmpty) {
      return DynamicLibrary.open(libraryPath);
    }
    if (Platform.isAndroid) {
      return DynamicLibrary.open('librnnoise.so');
    } else if (Platform.isIOS || Platform.isMacOS) {
      return DynamicLibrary.process();
    } else {
      throw UnsupportedError('rnnoise: platform not supported');
    }
  }

  RnnoiseStreamBindings? tryStreamBindings() {
    const symbols = [
      'rnnoise_stream_create',
      'rnnoise_stream_destroy',
      'rnnoise_stream_process',
      'rnnoise_stream_reset',
    ];
    if (!symbols.every(_lib.providesSymbol)) return null;
    return RnnoiseStreamBindings(_lib);
  }
}

typedef RnnoiseStreamCreateNative = Pointer<Void> Function(Int32);
typedef RnnoiseStreamCreate = Pointer<Void> Function(int);
typedef RnnoiseStreamDestroyNative = Void Function(Pointer<Void>);
typedef RnnoiseStreamDestroy = void Function(Pointer<Void>);
typedef RnnoiseStreamProcessNative = Int32 Function(
  Pointer<Void>,
  Pointer<Double>,
  Pointer<Double>,
  Int32,
  Double,
);
typedef RnnoiseStreamProcess = int Function(
  Pointer<Void>,
  Pointer<Double>,
  Pointer<Double>,
  int,
  double,
);
typedef RnnoiseStreamResetNative = Int32 Function(Pointer<Void>);
typedef RnnoiseStreamReset = int Function(Pointer<Void>);

class RnnoiseStreamBindings {
  RnnoiseStreamBindings(DynamicLibrary library)
      : create = library.lookupFunction<RnnoiseStreamCreateNative,
            RnnoiseStreamCreate>('rnnoise_stream_create'),
        destroy = library.lookupFunction<RnnoiseStreamDestroyNative,
            RnnoiseStreamDestroy>('rnnoise_stream_destroy'),
        process = library.lookupFunction<RnnoiseStreamProcessNative,
            RnnoiseStreamProcess>('rnnoise_stream_process'),
        reset = library.lookupFunction<RnnoiseStreamResetNative,
            RnnoiseStreamReset>('rnnoise_stream_reset');

  final RnnoiseStreamCreate create;
  final RnnoiseStreamDestroy destroy;
  final RnnoiseStreamProcess process;
  final RnnoiseStreamReset reset;
}
