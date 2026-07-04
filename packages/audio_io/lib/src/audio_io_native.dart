import 'dart:async';
import 'dart:io';

import 'audio_io_stub.dart';
import 'ffi/audio_io_ffi.dart';

class AudioIoNative implements AudioIoImpl {
  AudioIoFFI? _ffi;

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
}

AudioIoImpl createAudioIoImpl() => AudioIoNative();
