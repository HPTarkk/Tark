import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/services.dart';

import '../../../core/utils/logger.dart';

/// Bridge to Android's system-audio capture (see
/// android/.../audio/SystemAudioHandler.kt and SystemAudioCaptureService.kt).
///
/// Streams other apps' playback (music, navigation — never phone calls,
/// which no app can capture) as 16 kHz mono samples for mixing into the
/// transmit path. Android 10+ only; [isSupported] is false everywhere else,
/// including all of iOS (Apple offers no equivalent API without a
/// screen-broadcast extension).
abstract final class SystemAudioCapture {
  static const _methods = MethodChannel('tark/system_audio');
  static const _frameEvents = EventChannel('tark/system_audio/frames');

  static Stream<List<double>>? _frames;

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
    try {
      return await _methods.invokeMethod<bool>('start') ?? false;
    } catch (e) {
      Logger.log('System audio start failed: $e');
      return false;
    }
  }

  static Future<void> stop() async {
    try {
      await _methods.invokeMethod<void>('stop');
    } catch (e) {
      Logger.log('System audio stop failed: $e');
    }
  }

  /// Captured playback as normalized 16 kHz mono chunks (~100 ms each).
  static Stream<List<double>> get frames =>
      _frames ??= _frameEvents
          .receiveBroadcastStream()
          .map((event) => (event as Float64List).toList());
}
