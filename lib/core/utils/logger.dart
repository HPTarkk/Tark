import 'package:flutter/foundation.dart';

class Logger {
  const Logger._();

  /// Development-only tracing. Compiled out of release and profile builds.
  static void log(Object? data) {
    if (kDebugMode) print(data);
  }

  /// Emitted from every build, release included.
  ///
  /// Reserved for the few events that are rare, high-value, and diagnosable
  /// only on a real device — a signed release build on someone's phone is
  /// often the ONLY place a bug reproduces, and [log] says nothing there.
  ///
  /// `print` on purpose: it is what still reaches Android's logcat from an AOT
  /// build (under the `flutter` tag), whereas `dart:developer`'s log is inert
  /// there. Keep callers to genuinely occasional events — this is not for
  /// per-packet or per-frame paths.
  ///
  /// Read on a device with:
  ///     adb logcat -s flutter:I | grep tark-diag
  static void diagnostic(Object? data) {
    // ignore: avoid_print
    print('$diagnosticTag $data');
  }

  /// Prefix on every [diagnostic] line, so they can be grepped apart from
  /// everything else Flutter prints under the same logcat tag.
  static const diagnosticTag = 'tark-diag';
}
