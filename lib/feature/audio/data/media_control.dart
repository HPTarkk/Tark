import 'dart:io';

import 'package:flutter/services.dart';

import '../../../core/utils/logger.dart';

/// Bridge to Android's notification-listener-gated media session control
/// (see android/.../audio/MediaControlHandler.kt). Used to pause OTHER apps'
/// playback when the user stops music-casting — [SystemAudioCapture]'s
/// AudioPlaybackCapture never touches the source app, so this is the only
/// way to make "stop" actually silence the music. Android-only; requires the
/// user to grant "Notification access" once (a system settings toggle, not
/// an in-app permission dialog) — every method degrades to a silent no-op
/// without it.
abstract final class MediaControl {
  static const _methods = MethodChannel('tark/media_control');

  static Future<bool> hasAccess() async {
    if (!Platform.isAndroid) return false;
    try {
      return await _methods.invokeMethod<bool>('hasNotificationAccess') ??
          false;
    } catch (_) {
      return false;
    }
  }

  /// Opens the system "Notification access" settings screen.
  static Future<void> requestAccess() async {
    try {
      await _methods.invokeMethod<void>('requestNotificationAccess');
    } catch (e) {
      Logger.log('MediaControl requestAccess failed: $e');
    }
  }

  /// Pauses every other app's active media session. Silent no-op if access
  /// hasn't been granted.
  static Future<void> pauseOtherMedia() async {
    try {
      await _methods.invokeMethod<void>('pauseOtherMedia');
    } catch (e) {
      Logger.log('MediaControl pauseOtherMedia failed: $e');
    }
  }
}
