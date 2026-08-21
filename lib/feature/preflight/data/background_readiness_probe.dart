import 'dart:io';

import 'package:permission_handler/permission_handler.dart';

import '../../../core/utils/android_sdk.dart';

/// Resolves the raw platform signals [backgroundReadinessCheck] combines —
/// kept separate from that pure function the same way [MicProbe] is kept
/// separate from `mic_check`, so the decision logic stays testable without a
/// platform channel.
abstract final class BackgroundReadinessProbe {
  /// POST_NOTIFICATIONS only exists as a runtime permission from Android 13
  /// (SDK 33) — below that (and on every other platform) there is nothing to
  /// ask for, so it can never be the reason this check warns. Mirrors
  /// `permissions_page.dart`'s own SDK-gated pick, assuming modern Android
  /// when the native lookup itself fails rather than under-warning on a
  /// device this can't identify.
  static Future<bool> notificationRequired() async {
    if (!Platform.isAndroid) return false;
    try {
      return await AndroidSdk.version() >= 33;
    } catch (_) {
      return true;
    }
  }

  static Future<bool> notificationGranted() async {
    if (!Platform.isAndroid) return true;
    return (await Permission.notification.status).isGranted;
  }
}
