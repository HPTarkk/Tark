import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter/foundation.dart';

import '../../../core/audio/audio_format_profile.dart';
import '../../../core/utils/logger.dart';
import '../domain/capture_health.dart';
import 'media_control.dart';

/// Bridge to Android's system-audio capture.
///
/// Capture health is deliberately tracked here, at the source of truth. The
/// public frame streams only forward media while the classifier has real
/// audible evidence; starting/silent/blocked/stalled capture therefore cannot
/// transmit an endless empty Shared Music stream. Voice capture/routing is
/// unrelated and remains untouched.
abstract final class SystemAudioCapture {
  @visibleForTesting
  static bool? debugIsAndroid;

  static bool get _isAndroid => debugIsAndroid ?? Platform.isAndroid;
  static const _methods = MethodChannel('tark/system_audio');
  static const _frameEvents = EventChannel('tark/system_audio/frames');
  static const _hdFrameEvents = EventChannel('tark/system_audio/hd_frames');

  static Stream<List<double>>? _frames;
  static Stream<List<double>>? _hdFrames;
  static final CaptureHealthMonitor _monitor = CaptureHealthMonitor();
  static final StreamController<CaptureHealthSnapshot> _healthController =
      StreamController<CaptureHealthSnapshot>.broadcast();

  static Timer? _healthTimer;
  static bool _healthTickRunning = false;
  static int _healthGeneration = 0;
  static int _requestGeneration = 0;
  static bool _captureDesired = false;
  static bool _mediaPlayingKnown = false;
  static bool _externalMediaPlaying = false;
  static CaptureHealthSnapshot _latestHealth = const CaptureHealthSnapshot(
    state: CaptureHealthState.stopped,
    reasonCode: 'capture_not_started',
  );

  static const hdFormat = AudioFormatProfile.media48kStereo;

  static Stream<CaptureHealthSnapshot> get health => _healthController.stream;
  static CaptureHealthSnapshot get healthSnapshot => _latestHealth;

  static Future<bool> get isSupported async {
    if (!_isAndroid) return false;
    try {
      return await _methods.invokeMethod<bool>('isSupported') ?? false;
    } catch (_) {
      return false;
    }
  }

  /// Shows the system consent dialog and starts capturing on approval.
  /// Returns false when the user declines or capture is unavailable.
  static Future<bool> start() async {
    final request = ++_requestGeneration;
    _captureDesired = true;
    _cancelHealthTimer();
    Logger.diagnostic('mediaProjection: consent requested');
    final supported = await isSupported;
    if (request != _requestGeneration) return false;
    _monitor.reset();
    _monitor.start(DateTime.now(), supported: supported);
    _mediaPlayingKnown = false;
    _externalMediaPlaying = false;

    if (!supported) {
      _captureDesired = false;
      _publishHealth(
        _monitor.snapshot(
          DateTime.now(),
          mediaPlayingKnown: false,
          externalMediaPlaying: false,
        ),
      );
      Logger.diagnostic('mediaProjection: capture unsupported');
      return false;
    }

    _publishHealth(
      _monitor.snapshot(
        DateTime.now(),
        mediaPlayingKnown: false,
        externalMediaPlaying: false,
      ),
    );

    try {
      final started = await _methods.invokeMethod<bool>('start') ?? false;
      if (request != _requestGeneration) {
        // Older native binaries can finish consent after stop. Retire that
        // capture only when no newer request has taken ownership. Dispatching
        // stop here precedes any later request's native start on the channel.
        if (started && !_captureDesired) await _stopNativeCapture();
        return false;
      }
      Logger.diagnostic(
        started
            ? 'mediaProjection: capture start accepted'
            : 'mediaProjection: consent declined-or-unavailable',
      );
      if (started) {
        _startHealthTimer();
      } else {
        _captureDesired = false;
        _monitor.stop();
        _publishHealth(
          const CaptureHealthSnapshot(
            state: CaptureHealthState.stopped,
            reasonCode: 'capture_start_declined',
          ),
        );
      }
      return started;
    } catch (e) {
      if (request != _requestGeneration) return false;
      _captureDesired = false;
      _monitor.stop();
      _publishHealth(
        const CaptureHealthSnapshot(
          state: CaptureHealthState.stopped,
          reasonCode: 'capture_start_failed',
        ),
      );
      Logger.diagnostic(
        'mediaProjection: capture start failed '
        'reason=${_safeErrorCode(e)}',
      );
      Logger.log('System audio start failed: $e');
      return false;
    }
  }

  static Future<void> stop() async {
    _requestGeneration++;
    _captureDesired = false;
    Logger.diagnostic('mediaProjection: capture stop requested');
    _cancelHealthTimer();
    _monitor.stop();
    _publishHealth(
      _monitor.snapshot(
        DateTime.now(),
        mediaPlayingKnown: _mediaPlayingKnown,
        externalMediaPlaying: _externalMediaPlaying,
      ),
    );
    await _stopNativeCapture();
  }

  static Future<void> _stopNativeCapture() async {
    try {
      await _methods.invokeMethod<void>('stop');
      Logger.diagnostic('mediaProjection: capture stopped');
    } catch (e) {
      Logger.diagnostic(
        'mediaProjection: capture stop failed '
        'reason=${_safeErrorCode(e)}',
      );
      Logger.log('System audio stop failed: $e');
    }
  }

  static void _startHealthTimer() {
    _cancelHealthTimer();
    final generation = _healthGeneration;
    _healthTimer = Timer.periodic(
      const Duration(milliseconds: 500),
      (_) => _refreshHealth(generation),
    );
    unawaited(_refreshHealth(generation));
  }

  static void _cancelHealthTimer() {
    _healthTimer?.cancel();
    _healthTimer = null;
    _healthTickRunning = false;
    _healthGeneration++;
  }

  static Future<void> _refreshHealth(int generation) async {
    if (generation != _healthGeneration || _healthTickRunning) return;
    _healthTickRunning = true;
    try {
      final hasAccess = await MediaControl.hasAccess();
      if (generation != _healthGeneration) return;
      final playing = hasAccess
          ? await MediaControl.isOtherMediaPlaying()
          : false;
      if (generation != _healthGeneration) return;
      _mediaPlayingKnown = hasAccess;
      _externalMediaPlaying = playing;
      _publishHealth(
        _monitor.snapshot(
          DateTime.now(),
          mediaPlayingKnown: hasAccess,
          externalMediaPlaying: playing,
        ),
      );
    } finally {
      if (generation == _healthGeneration) _healthTickRunning = false;
    }
  }

  static List<double>? _guardFrame(List<double> samples) {
    final snapshot = _monitor.observeFrame(
      samples,
      DateTime.now(),
      mediaPlayingKnown: _mediaPlayingKnown,
      externalMediaPlaying: _externalMediaPlaying,
    );
    _publishHealth(snapshot);
    return snapshot.mayTransmitMedia ? samples : null;
  }

  static List<double>? _decodeAndGuardFrame(Object? event, int channels) {
    // Bad or empty callbacks are not evidence that capture is still alive.
    // Infinity would otherwise produce an infinite RMS and appear audible.
    if (event is! Float64List ||
        event.isEmpty ||
        event.length % channels != 0) {
      return null;
    }
    for (final sample in event) {
      if (!sample.isFinite) return null;
    }
    return _guardFrame(event.toList());
  }

  static void _publishHealth(CaptureHealthSnapshot snapshot) {
    final previous = _latestHealth;
    _latestHealth = snapshot;
    if (previous.state != snapshot.state ||
        previous.reasonCode != snapshot.reasonCode) {
      Logger.diagnostic(
        'mediaProjection: health state=${snapshot.state.name} '
        'reason=${snapshot.reasonCode} '
        'firstAudibleMs=${snapshot.timeToFirstAudibleFrameMs ?? -1}',
      );
    }
    if (!_healthController.isClosed) {
      _healthController.add(snapshot);
    }
  }

  static String _safeErrorCode(Object error) => switch (error) {
    PlatformException(:final code) => code,
    MissingPluginException() => 'missing_plugin',
    _ => error.runtimeType.toString(),
  };

  static Future<void> setLocalVolume(double gain) async {
    try {
      await _methods.invokeMethod<void>('setLocalVolume', {'gain': gain});
    } catch (e) {
      Logger.log('System audio setLocalVolume failed: $e');
    }
  }

  /// Captured playback as normalized 16 kHz mono chunks. Frames are forwarded
  /// only while capture health is [CaptureHealthState.audible].
  static Stream<List<double>> get frames => _frames ??= _frameEvents
      .receiveBroadcastStream()
      .map((event) => _decodeAndGuardFrame(event, 1))
      .where((frame) => frame != null)
      .cast<List<double>>();

  /// Captured playback as 48 kHz interleaved stereo. It shares the same health
  /// guard as [frames], so independent HD mode cannot bypass blocked/stalled
  /// capture protection.
  static Stream<List<double>> get hdFrames => _hdFrames ??= _hdFrameEvents
      .receiveBroadcastStream()
      .map((event) => _decodeAndGuardFrame(event, hdFormat.channels))
      .where((frame) => frame != null)
      .cast<List<double>>();
}
