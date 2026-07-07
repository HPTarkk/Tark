import 'dart:io';

import 'package:flutter/services.dart';

import '../../../core/utils/logger.dart';

/// Bridge to the native session keep-alive (see
/// android/.../keepalive/SessionKeepAliveService.kt and KeepAliveHandler.kt).
///
/// While a walkie session runs, a foreground service holds the CPU and Wi-Fi
/// awake so audio and UDP keep flowing with the screen off — the motorcycle
/// use case. Android-only; every method is a no-op elsewhere. Best-effort by
/// design: a missing channel or native failure just means no keep-alive, never
/// a crash.
abstract final class SessionKeepAlive {
  static const _channel = MethodChannel('tark/keepalive');

  static bool get _supported => Platform.isAndroid;

  /// Starts the foreground service + wake/Wi-Fi/multicast locks.
  static Future<void> start() async {
    if (!_supported) return;
    try {
      await _channel.invokeMethod<void>('start');
    } catch (e) {
      Logger.log('Keep-alive start failed: $e');
    }
  }

  /// Stops the service and releases all locks.
  static Future<void> stop() async {
    if (!_supported) return;
    try {
      await _channel.invokeMethod<void>('stop');
    } catch (e) {
      Logger.log('Keep-alive stop failed: $e');
    }
  }

  /// Whether the app is already exempt from Doze battery optimization.
  static Future<bool> isIgnoringBatteryOptimizations() async {
    if (!_supported) return true;
    try {
      return await _channel
              .invokeMethod<bool>('isIgnoringBatteryOptimizations') ??
          true;
    } catch (_) {
      return true;
    }
  }

  /// Shows the system "allow background / ignore battery optimizations" dialog.
  static Future<void> requestIgnoreBatteryOptimizations() async {
    if (!_supported) return;
    try {
      await _channel.invokeMethod<void>('requestIgnoreBatteryOptimizations');
    } catch (e) {
      Logger.log('Battery optimization request failed: $e');
    }
  }

  /// Whether this is a MIUI (Xiaomi) ROM, which needs the extra Autostart step.
  static Future<bool> isMiui() async {
    if (!_supported) return false;
    try {
      return await _channel.invokeMethod<bool>('isMiui') ?? false;
    } catch (_) {
      return false;
    }
  }

  /// Opens MIUI's Autostart manager (or app-details as a fallback).
  static Future<void> openAutoStartSettings() async {
    if (!_supported) return;
    try {
      await _channel.invokeMethod<void>('openAutoStartSettings');
    } catch (e) {
      Logger.log('Open autostart settings failed: $e');
    }
  }
}
