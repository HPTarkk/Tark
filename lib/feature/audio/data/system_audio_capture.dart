import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/services.dart';

import '../../../core/audio/audio_format_profile.dart';
import '../../../core/utils/logger.dart';

/// Bridge to Android's system-audio capture (see
/// android/.../audio/SystemAudioHandler.kt and SystemAudioCaptureService.kt).
///
/// Streams other apps' playback (music, navigation — never phone calls,
/// which no app can capture). Android 10+ only; [isSupported] is false
/// everywhere else, including all of iOS (Apple offers no equivalent API
/// without a screen-broadcast extension).
///
/// Two independent streams come off the same native capture:
/// - [frames]: 16 kHz mono, for mixing into the transmit path — what
///   `MusicMixer` has always consumed, unchanged.
/// - [hdFrames] (#29): genuine 48 kHz interleaved stereo, matching
///   [AudioFormatProfile.media48kStereo] — [hdFormat] describes what it
///   carries. Nothing in production subscribes to this yet; it exists for
///   the HD Shared Music codec/profile work ahead of #30's network
///   integration. Subscribing has no effect on [frames].
abstract final class SystemAudioCapture {
  static const _methods = MethodChannel('tark/system_audio');
  static const _frameEvents = EventChannel('tark/system_audio/frames');
  static const _hdFrameEvents = EventChannel('tark/system_audio/hd_frames');

  static Stream<List<double>>? _frames;
  static Stream<List<double>>? _hdFrames;

  /// The wire-format contract [hdFrames] always delivers. A constant, not a
  /// query, because the native capture path always requests Android's one
  /// guaranteed-supported playback-capture format (48 kHz stereo) — see
  /// `SystemAudioCaptureService.CAPTURE_RATE`. If a genuinely mono capture
  /// source is ever added, this becomes a real per-session query instead of
  /// a constant.
  static const hdFormat = AudioFormatProfile.media48kStereo;

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
    try {
      final started = await _methods.invokeMethod<bool>('start') ?? false;
      Logger.diagnostic(
        started
            ? 'mediaProjection: capture start accepted'
            : 'mediaProjection: consent declined-or-unavailable',
      );
      return started;
    } catch (e) {
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

  /// Diagnostic errors are intentionally reduced to stable codes. Platform
  /// exception messages can include OEM/vendor detail we do not need in the
  /// report, and arbitrary exception `toString()` output is not a privacy
  /// boundary.
  static String _safeErrorCode(Object error) => switch (error) {
    PlatformException(:final code) => code,
    MissingPluginException() => 'missing_plugin',
    _ => error.runtimeType.toString(),
  };

  /// Nudges this device's own STREAM_MUSIC volume to match [gain] (0-1), so
  /// the broadcaster's own speaker follows the in-app mix slider instead of
  /// only affecting what peers hear. AudioPlaybackCapture has no API to
  /// mute/adjust the source app specifically, so this is a system-wide media
  /// volume change — the closest available proxy.
  static Future<void> setLocalVolume(double gain) async {
    try {
      await _methods.invokeMethod<void>('setLocalVolume', {'gain': gain});
    } catch (e) {
      Logger.log('System audio setLocalVolume failed: $e');
    }
  }

  /// Captured playback as normalized 16 kHz mono chunks (~100 ms each).
  static Stream<List<double>> get frames => _frames ??= _frameEvents
      .receiveBroadcastStream()
      .map((event) => (event as Float64List).toList());

  /// Captured playback as normalized, genuinely 48 kHz interleaved-stereo
  /// chunks (~100 ms each; interleaved sample count, so ~2x [frames]'
  /// element count for the same time window) — see [hdFormat] and the class
  /// doc. Independent broadcast stream from [frames]; starting/stopping a
  /// subscription here doesn't touch the legacy path.
  static Stream<List<double>> get hdFrames => _hdFrames ??= _hdFrameEvents
      .receiveBroadcastStream()
      .map((event) => (event as Float64List).toList());
}
