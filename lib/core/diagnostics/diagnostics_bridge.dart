import 'dart:io';

import 'package:flutter/services.dart';

/// Platform bits the diagnostic log needs and Dart cannot answer on its own: a
/// private directory to keep the log in, and the system share sheet to get it
/// off the phone.
///
/// Written as a native handler rather than pulled in as packages
/// (path_provider + share_plus) on purpose. Both would have worked, but
/// share_plus's current release requires a newer Android Gradle Plugin than
/// this project is on, and bumping the build toolchain to add a share sheet is
/// a far bigger change — with a far larger blast radius — than the ~60 lines of
/// Kotlin/Swift it replaces. See DiagnosticsHandler.kt / DiagnosticsHandler.swift.
///
/// Every method is best-effort: diagnostics must never be the thing that
/// crashes a session.
abstract final class DiagnosticsBridge {
  static const _channel = MethodChannel('tark/diagnostics');

  /// Android and iOS only — the two platforms with a handler behind this
  /// channel. This file imports `dart:io`, so it is never reached by the web
  /// guest build in the first place.
  static bool get isSupported => Platform.isAndroid || Platform.isIOS;

  /// App-private directory the log lives in.
  ///
  /// Deliberately NOT the cache directory: the OS clears caches under storage
  /// pressure, which is exactly the kind of moment a session misbehaves and
  /// the log is worth having. Android returns `filesDir`, iOS returns
  /// Application Support — both private to the app and both survive a restart.
  static Future<String?> logsDirectory() async {
    if (!isSupported) return null;
    try {
      return await _channel.invokeMethod<String>('logsDirectory');
    } catch (_) {
      return null;
    }
  }

  /// Hands [path] to the system share sheet.
  ///
  /// Returns false when there was nothing to share with — no share target, or
  /// the platform refused — so the caller can say so instead of leaving the
  /// user tapping a button that appears to do nothing.
  static Future<bool> shareFile({
    required String path,
    required String mimeType,
    String? subject,
  }) async {
    if (!isSupported) return false;
    try {
      return await _channel.invokeMethod<bool>('shareFile', {
            'path': path,
            'mimeType': mimeType,
            'subject': subject ?? '',
          }) ??
          false;
    } catch (_) {
      return false;
    }
  }
}
