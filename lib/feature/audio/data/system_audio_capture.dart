import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/services.dart';

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
    if (!Platform.isAndroid) return false;
    try {
      return await _methods.invokeMethod<bool>('isSupported') ?? false;
    } catch (_) {
      return false;
    }
  }

  /// Shows the system consent dialog and starts capturing on approval.
  /// Returns false when the user declines or capture is unavailable.
  static Future<bool> start() async {
    Logger.diagnostic('mediaProjection: consent requested');
    final supported = await isSupported;
    _monitor.reset();
    _monitor.start(DateTime.now(), supported: supported);
    _mediaPlayingKnown = false;
    _externalMediaPlaying = false;

    if (!supported) {
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
      Logger.diagnostic(
        started
            ? 'mediaProjection: capture start accepted'
            : 'mediaProjection: consent declined-or-unavailable',
      );
      if (started) {
        _startHealthTimer();
      } else {
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
    Logger.diagnostic('mediaProjection: capture stop requested');
    _healthTimer?.cancel();
    _healthTimer = null;
    _healthTickRunning = false;
    _monitor.stop();
    _publishHealth(
      _monitor.snapshot(
        DateTime.now(),
        mediaPlayingKnown: _mediaPlayingKnown,
        externalMediaPlaying: _externalMediaPlaying,
      ),
    );
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
    _healthTimer?.cancel();
    _healthTimer = Timer.periodic(
      const Duration(milliseconds: 500),
      (_) => _refreshHealth(),
    );
    unawaited(_refreshHealth());
  }

  static Future<void> _refreshHealth() async {
    if (_healthTickRunning) return;
    _healthTickRunning = true;
    try {
      final hasAccess = await MediaControl.hasAccess();
      final playing = hasAccess
          ? await MediaControl.isOtherMediaPlaying()
          : false;
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
      _healthTickRunning = false;
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
      .map((event) => (event as Float64List).toList())
      .map(_guardFrame)
      .where((frame) => frame != null)
      .cast<List<double>>();

  /// Captured playback as 48 kHz interleaved stereo. It shares the same health
  /// guard as [frames], so independent HD mode cannot bypass blocked/stalled
  /// capture protection.
  static Stream<List<double>> get hdFrames => _hdFrames ??= _hdFrameEvents
      .receiveBroadcastStream()
      .map((event) => (event as Float64List).toList())
      .map(_guardFrame)
      .where((frame) => frame != null)
      .cast<List<double>>();
}
