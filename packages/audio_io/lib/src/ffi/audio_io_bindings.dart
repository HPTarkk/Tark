import 'dart:ffi';
import 'dart:io';

typedef AudioIoCreateNative = Pointer<Void> Function();
typedef AudioIoCreate = Pointer<Void> Function();

typedef AudioIoDestroyNative = Void Function(Pointer<Void> handle);
typedef AudioIoDestroy = void Function(Pointer<Void> handle);

typedef AudioIoStartNative = Int32 Function(Pointer<Void> handle);
typedef AudioIoStart = int Function(Pointer<Void> handle);

typedef AudioIoStopNative = Int32 Function(Pointer<Void> handle);
typedef AudioIoStop = int Function(Pointer<Void> handle);

typedef AudioIoReadNative = Int32 Function(
    Pointer<Void> handle, Pointer<Double> buffer, Int32 frameCount);
typedef AudioIoRead = int Function(
    Pointer<Void> handle, Pointer<Double> buffer, int frameCount);

typedef AudioIoWriteNative = Int32 Function(
    Pointer<Void> handle, Pointer<Double> buffer, Int32 frameCount);
typedef AudioIoWrite = int Function(
    Pointer<Void> handle, Pointer<Double> buffer, int frameCount);

typedef AudioIoGetSampleRateNative = Int32 Function(Pointer<Void> handle);
typedef AudioIoGetSampleRate = int Function(Pointer<Void> handle);

typedef AudioIoGetChannelsNative = Int32 Function(Pointer<Void> handle);
typedef AudioIoGetChannels = int Function(Pointer<Void> handle);

typedef AudioIoGetAvailableReadFramesNative = Int32 Function(
    Pointer<Void> handle);
typedef AudioIoGetAvailableReadFrames = int Function(Pointer<Void> handle);

typedef AudioIoGetAvailableWriteSpaceNative = Int32 Function(
    Pointer<Void> handle);
typedef AudioIoGetAvailableWriteSpace = int Function(Pointer<Void> handle);

typedef AudioIoSetFrameDurationNative = Int32 Function(
    Pointer<Void> handle, Double duration);
typedef AudioIoSetFrameDuration = int Function(
    Pointer<Void> handle, double duration);

typedef AudioIoGetFrameDurationNative = Double Function(Pointer<Void> handle);
typedef AudioIoGetFrameDuration = double Function(Pointer<Void> handle);

class AudioIoBindings {
  late final DynamicLibrary _lib;

  late final AudioIoCreate create;
  late final AudioIoDestroy destroy;
  late final AudioIoStart start;
  late final AudioIoStop stop;
  late final AudioIoRead read;
  late final AudioIoWrite write;
  late final AudioIoGetSampleRate getSampleRate;
  late final AudioIoGetChannels getChannels;
  late final AudioIoGetAvailableReadFrames getAvailableReadFrames;
  late final AudioIoGetAvailableWriteSpace getAvailableWriteSpace;
  late final AudioIoSetFrameDuration setFrameDuration;
  late final AudioIoGetFrameDuration getFrameDuration;

  AudioIoBindings() {
    _lib = _loadLibrary();

    create = _lib
        .lookup<NativeFunction<AudioIoCreateNative>>('audio_io_create')
        .asFunction();

    destroy = _lib
        .lookup<NativeFunction<AudioIoDestroyNative>>('audio_io_destroy')
        .asFunction();

    start = _lib
        .lookup<NativeFunction<AudioIoStartNative>>('audio_io_start')
        .asFunction();

    stop = _lib
        .lookup<NativeFunction<AudioIoStopNative>>('audio_io_stop')
        .asFunction();

    read = _lib
        .lookup<NativeFunction<AudioIoReadNative>>('audio_io_read')
        .asFunction();

    write = _lib
        .lookup<NativeFunction<AudioIoWriteNative>>('audio_io_write')
        .asFunction();

    getSampleRate = _lib
        .lookup<NativeFunction<AudioIoGetSampleRateNative>>(
            'audio_io_get_sample_rate')
        .asFunction();

    getChannels = _lib
        .lookup<NativeFunction<AudioIoGetChannelsNative>>(
            'audio_io_get_channels')
        .asFunction();

    getAvailableReadFrames = _lib
        .lookup<NativeFunction<AudioIoGetAvailableReadFramesNative>>(
            'audio_io_get_available_read_frames')
        .asFunction();

    getAvailableWriteSpace = _lib
        .lookup<NativeFunction<AudioIoGetAvailableWriteSpaceNative>>(
            'audio_io_get_available_write_space')
        .asFunction();

    setFrameDuration = _lib
        .lookup<NativeFunction<AudioIoSetFrameDurationNative>>(
            'audio_io_set_frame_duration')
        .asFunction();

    getFrameDuration = _lib
        .lookup<NativeFunction<AudioIoGetFrameDurationNative>>(
            'audio_io_get_frame_duration')
        .asFunction();
  }

  static DynamicLibrary _loadLibrary() {
    if (Platform.isAndroid) {
      return DynamicLibrary.open('libaudio_io.so');
    } else if (Platform.isLinux) {
      return DynamicLibrary.open('libaudio_io.so');
    } else if (Platform.isWindows) {
      return DynamicLibrary.open('audio_io.dll');
    } else if (Platform.isMacOS) {
      return DynamicLibrary.process();
    } else if (Platform.isIOS) {
      return DynamicLibrary.process();
    } else {
      throw UnsupportedError('Platform not supported');
    }
  }
}
