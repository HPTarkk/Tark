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

typedef AudioIoGetInputSessionIdNative = Int32 Function(Pointer<Void> handle);
typedef AudioIoGetInputSessionId = int Function(Pointer<Void> handle);

typedef AudioIoGetOutputUnderrunFramesNative = Int64 Function(
    Pointer<Void> handle);
typedef AudioIoGetOutputUnderrunFrames = int Function(Pointer<Void> handle);

typedef AudioIoGetOutputQueuedFramesNative = Int32 Function(
    Pointer<Void> handle);
typedef AudioIoGetOutputQueuedFrames = int Function(Pointer<Void> handle);

typedef AudioIoVoiceWriteNative = Int32 Function(
    Pointer<Void> handle, Pointer<Double> buffer, Int32 frameCount);
typedef AudioIoVoiceWrite = int Function(
    Pointer<Void> handle, Pointer<Double> buffer, int frameCount);

typedef AudioIoVoiceWriteZerosNative = Int32 Function(
    Pointer<Void> handle, Int32 frameCount);
typedef AudioIoVoiceWriteZeros = int Function(
    Pointer<Void> handle, int frameCount);

typedef AudioIoVoiceSetTargetNative = Void Function(
    Pointer<Void> handle, Int32 frames);
typedef AudioIoVoiceSetTarget = void Function(Pointer<Void> handle, int frames);

typedef AudioIoVoiceResetNative = Void Function(Pointer<Void> handle);
typedef AudioIoVoiceReset = void Function(Pointer<Void> handle);

typedef AudioIoReleaseAllNative = Int32 Function();
typedef AudioIoReleaseAll = int Function();

typedef AudioIoVoiceStatNative = Int64 Function(
    Pointer<Void> handle, Int32 which);
typedef AudioIoVoiceStat = int Function(Pointer<Void> handle, int which);

typedef AudioIoDspCreateNative = Pointer<Void> Function(Double a, Double b);
typedef AudioIoDspCreate = Pointer<Void> Function(double a, double b);
typedef AudioIoDspDestroyNative = Void Function(Pointer<Void> handle);
typedef AudioIoDspDestroy = void Function(Pointer<Void> handle);
typedef AudioIoResamplerCapacityNative = Int32 Function(
    Pointer<Void> handle, Int32 inputFrames);
typedef AudioIoResamplerCapacity = int Function(
    Pointer<Void> handle, int inputFrames);
typedef AudioIoResamplerProcessNative = Int32 Function(
    Pointer<Void> handle,
    Pointer<Double> input,
    Int32 inputFrames,
    Pointer<Double> output,
    Int32 outputCapacity);
typedef AudioIoResamplerProcess = int Function(
    Pointer<Void> handle,
    Pointer<Double> input,
    int inputFrames,
    Pointer<Double> output,
    int outputCapacity);
typedef AudioIoDspResetNative = Void Function(Pointer<Void> handle);
typedef AudioIoDspReset = void Function(Pointer<Void> handle);
typedef AudioIoLowPassProcessNative = Void Function(Pointer<Void> handle,
    Pointer<Double> input, Pointer<Double> output, Int32 frames);
typedef AudioIoLowPassProcess = void Function(Pointer<Void> handle,
    Pointer<Double> input, Pointer<Double> output, int frames);

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
  late final AudioIoGetInputSessionId getInputSessionId;
  late final AudioIoGetOutputUnderrunFrames getOutputUnderrunFrames;
  late final AudioIoGetOutputQueuedFrames getOutputQueuedFrames;
  late final AudioIoVoiceWrite voiceWrite;
  late final AudioIoVoiceWriteZeros voiceWriteZeros;
  late final AudioIoVoiceSetTarget voiceSetTarget;
  late final AudioIoVoiceReset voiceReset;
  late final AudioIoVoiceStat voiceStat;
  late final AudioIoDspCreate resamplerCreate;
  late final AudioIoDspDestroy resamplerDestroy;
  late final AudioIoResamplerCapacity resamplerOutputCapacity;
  late final AudioIoResamplerProcess resamplerProcess;
  late final AudioIoDspReset resamplerReset;
  late final AudioIoDspCreate lowPassCreate;
  late final AudioIoDspDestroy lowPassDestroy;
  late final AudioIoLowPassProcess lowPassProcess;
  late final AudioIoDspReset lowPassReset;

  /// Null where the native library predates it.
  late final AudioIoReleaseAll? releaseAll;

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

    getInputSessionId = _lib
        .lookup<NativeFunction<AudioIoGetInputSessionIdNative>>(
            'audio_io_get_input_session_id')
        .asFunction();

    getOutputUnderrunFrames = _lib
        .lookup<NativeFunction<AudioIoGetOutputUnderrunFramesNative>>(
            'audio_io_get_output_underrun_frames')
        .asFunction();

    getOutputQueuedFrames = _lib
        .lookup<NativeFunction<AudioIoGetOutputQueuedFramesNative>>(
            'audio_io_get_output_queued_frames')
        .asFunction();

    voiceWrite = _lib
        .lookup<NativeFunction<AudioIoVoiceWriteNative>>('audio_io_voice_write')
        .asFunction();
    voiceWriteZeros = _lib
        .lookup<NativeFunction<AudioIoVoiceWriteZerosNative>>(
            'audio_io_voice_write_zeros')
        .asFunction();
    voiceSetTarget = _lib
        .lookup<NativeFunction<AudioIoVoiceSetTargetNative>>(
            'audio_io_voice_set_target')
        .asFunction();
    voiceReset = _lib
        .lookup<NativeFunction<AudioIoVoiceResetNative>>('audio_io_voice_reset')
        .asFunction();
    voiceStat = _lib
        .lookup<NativeFunction<AudioIoVoiceStatNative>>('audio_io_voice_stat')
        .asFunction();
    resamplerCreate = _lib
        .lookup<NativeFunction<AudioIoDspCreateNative>>(
            'audio_io_resampler_create')
        .asFunction();
    resamplerDestroy = _lib
        .lookup<NativeFunction<AudioIoDspDestroyNative>>(
            'audio_io_resampler_destroy')
        .asFunction();
    resamplerOutputCapacity = _lib
        .lookup<NativeFunction<AudioIoResamplerCapacityNative>>(
            'audio_io_resampler_output_capacity')
        .asFunction();
    resamplerProcess = _lib
        .lookup<NativeFunction<AudioIoResamplerProcessNative>>(
            'audio_io_resampler_process')
        .asFunction();
    resamplerReset = _lib
        .lookup<NativeFunction<AudioIoDspResetNative>>(
            'audio_io_resampler_reset')
        .asFunction();
    lowPassCreate = _lib
        .lookup<NativeFunction<AudioIoDspCreateNative>>(
            'audio_io_low_pass_create')
        .asFunction();
    lowPassDestroy = _lib
        .lookup<NativeFunction<AudioIoDspDestroyNative>>(
            'audio_io_low_pass_destroy')
        .asFunction();
    lowPassProcess = _lib
        .lookup<NativeFunction<AudioIoLowPassProcessNative>>(
            'audio_io_low_pass_process')
        .asFunction();
    lowPassReset = _lib
        .lookup<NativeFunction<AudioIoDspResetNative>>(
            'audio_io_low_pass_reset')
        .asFunction();
    releaseAll = _lib.providesSymbol('audio_io_release_all')
        ? _lib
            .lookup<NativeFunction<AudioIoReleaseAllNative>>(
                'audio_io_release_all')
            .asFunction()
        : null;
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
