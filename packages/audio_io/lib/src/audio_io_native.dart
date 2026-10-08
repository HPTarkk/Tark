import 'dart:async';
import 'dart:io';

import 'audio_io_stub.dart';
import 'voice_queue.dart';
import 'realtime_dsp.dart';
import 'ffi/audio_io_ffi.dart';
import 'ffi/audio_io_bindings.dart';

class AudioIoNative implements AudioIoImpl {
  AudioIoNative({AudioIoBindings? realtimeBindings})
      : _realtimeBindings = realtimeBindings;

  final AudioIoBindings? _realtimeBindings;
  AudioIoFFI? _ffi;

  AudioIoBindings get _dspBindings =>
      _realtimeBindings ?? AudioIoFFI.instance.bindings;

  @override
  bool get usePlatformImpl =>
      Platform.isAndroid || Platform.isWindows || Platform.isLinux;

  @override
  Stream<List<double>>? get inputAudioStream => _ffi?.inputAudioStream;

  @override
  StreamSink<List<double>>? get outputAudioStream => _ffi?.outputAudioStream;

  @override
  Future<void> start() async {
    _ffi = AudioIoFFI.instance;
    await _ffi!.start();
  }

  @override
  Future<void> stop() async {
    await _ffi?.stop();
  }

  @override
  Map<String, dynamic> getFormat() {
    return _ffi?.getFormat() ??
        {
          'input': {
            'type': 'double',
            'channels': 1,
            'sampleRate': 48000.0,
          },
          'output': {
            'type': 'double',
            'channels': 1,
            'sampleRate': 48000.0,
          },
        };
  }

  @override
  Future<void> requestFrameDuration(double duration) async {
    await _ffi?.requestFrameDuration(duration);
  }

  @override
  Future<double> getFrameDuration() async {
    return await _ffi?.getFrameDuration() ?? 0.01;
  }

  @override
  int getInputSessionId() => _ffi?.getInputSessionId() ?? -1;

  @override
  int getOutputUnderrunFrames() => _ffi?.getOutputUnderrunFrames() ?? 0;

  @override
  int getOutputQueuedFrames() => _ffi?.getOutputQueuedFrames() ?? -1;

  @override
  VoiceQueue? get voiceQueue =>
      usePlatformImpl ? AudioIoFFI.instance.voiceQueue : null;

  @override
  RealtimeResampler? createRealtimeResampler(double inRate, double outRate) {
    if (!usePlatformImpl) return null;
    final bindings = _dspBindings;
    return bindings.hasResampler
        ? FfiRealtimeResampler.create(bindings, inRate, outRate)
        : null;
  }

  @override
  RealtimeLowPass? createRealtimeLowPass(double sampleRate, double cutoffHz) {
    if (!usePlatformImpl) return null;
    final bindings = _dspBindings;
    return bindings.hasLowPass
        ? FfiRealtimeLowPass.create(bindings, sampleRate, cutoffHz)
        : null;
  }

  @override
  RealtimeSpectralSuppressor? createRealtimeSpectralSuppressor(int sampleRate) {
    if (!usePlatformImpl) return null;
    final bindings = _dspBindings;
    return bindings.hasSpectralSuppressor
        ? FfiRealtimeSpectralSuppressor.create(bindings, sampleRate)
        : null;
  }
}

AudioIoImpl createAudioIoImpl() => AudioIoNative();
