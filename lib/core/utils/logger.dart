import 'package:flutter/foundation.dart';

class Logger {
  const Logger._();

  /// Where log lines are mirrored for on-device capture, or null when nothing
  /// is capturing.
  ///
  /// A plain function rather than an interface, and set from `main()` rather
  /// than injected, so `core/utils` keeps importing nothing: [Logger] is
  /// reached from every layer of the app (including the web guest build, which
  /// has no `dart:io` and no file to write to), and giving it a dependency on
  /// the file store would drag that store everywhere too.
  ///
  /// See [DiagnosticLog], which installs itself here.
  static void Function(String line)? sink;

  /// Development-only tracing. Compiled out of release and profile builds.
  static void log(Object? data) {
    if (kDebugMode) {
      print(data);
      _capture('$data');
    }
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
  ///
  /// …or, on a phone that isn't plugged into anything, from Settings →
  /// Advanced → Diagnostics → Share log, which is where [sink] sends these.
  static void diagnostic(Object? data) {
    // ignore: avoid_print
    print('$diagnosticTag $data');
    _capture('$data');
  }

  /// Prefix on every [diagnostic] line, so they can be grepped apart from
  /// everything else Flutter prints under the same logcat tag.
  static const diagnosticTag = 'tark-diag';

  /// A broken capture must never take down the thing it was watching, so the
  /// sink is called defensively and its failures are dropped on the floor.
  static void _capture(String line) {
    final target = sink;
    if (target == null) return;
    try {
      target(line);
    } catch (_) {
      // Nothing sensible to do here — logging the failure would recurse.
    }
  }
}
