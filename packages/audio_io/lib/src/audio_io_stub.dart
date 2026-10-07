import 'dart:async';

import 'voice_queue.dart';
import 'realtime_dsp.dart';

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

  /// Platform audio session id of the capture stream (for attaching native
  /// voice effects), or -1 when unavailable.
  int getInputSessionId();

  /// Cumulative frames the playback callback had to fill with silence because
  /// the output ring was empty. Diagnostic only — each such frame is an
  /// audible tick, so a climbing value means the feed isn't staying ahead of
  /// the device.
  int getOutputUnderrunFrames();

  /// Samples handed to the output that the device has not played yet, or -1
  /// where the platform cannot say.
  int getOutputQueuedFrames();

  /// The native received-voice queue, or null where playback is not driven
  /// by miniaudio (iOS, macOS, web).
  VoiceQueue? get voiceQueue;

  RealtimeResampler? createRealtimeResampler(double inRate, double outRate);
  RealtimeLowPass? createRealtimeLowPass(double sampleRate, double cutoffHz);
  RealtimeSpectralSuppressor? createRealtimeSpectralSuppressor(int sampleRate);
}

AudioIoImpl createAudioIoImpl() => throw UnsupportedError(
    'Cannot create audio implementation on this platform');
