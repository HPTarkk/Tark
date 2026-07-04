import 'dart:async';

/// Stub implementation for platform detection
abstract class AudioIoImpl {
  bool get usePlatformImpl;
  Stream<List<double>>? get inputAudioStream;
  StreamSink<List<double>>? get outputAudioStream;

  Future<void> start();
  Future<void> stop();
  Map<String, dynamic> getFormat();
  Future<void> requestFrameDuration(double duration);
  Future<double> getFrameDuration();
}

AudioIoImpl createAudioIoImpl() => throw UnsupportedError(
    'Cannot create audio implementation on this platform');
