import 'dart:async';

import 'package:flutter/widgets.dart';

import '../utils/logger.dart';
import 'diagnostic_log.dart';

/// Records when the app leaves and returns to the foreground, and how long it
/// was away.
///
/// This is the single most useful line in the log for the failures this app
/// actually has. Almost everything that goes wrong mid-session goes wrong
/// *because* the screen locked: Android releases an app-scoped Wi-Fi request
/// when the process stops being foreground, Doze throttles timers, an OEM
/// battery manager suspends the process outright, and a SoftAP can be torn
/// down by the radio underneath all of it. Without a timestamped
/// "backgrounded here, resumed 47s later" in the same file as the socket and
/// audio events, every one of those reads as a spontaneous failure.
///
/// It also [DiagnosticLog.flush]es on the way out, which is the other half:
/// the process is most likely to be killed while it is in the background, and
/// unflushed lines describing what happened just before are exactly the ones
/// worth not losing.
class LifecycleLog with WidgetsBindingObserver {
  LifecycleLog._();

  static final LifecycleLog _instance = LifecycleLog._();
  static bool _installed = false;

  /// Registers the observer. Idempotent — a second call is a no-op rather than
  /// a second set of duplicate log lines.
  static void install() {
    if (_installed) return;
    _installed = true;
    WidgetsBinding.instance.addObserver(_instance);
  }

  static void uninstall() {
    if (!_installed) return;
    _installed = false;
    WidgetsBinding.instance.removeObserver(_instance);
  }

  /// When the app last stopped being visible, so a resume can report the gap
  /// rather than just its own timestamp.
  DateTime? _leftAt;

  /// Whether the app is in the foreground right now. Read by session code that
  /// needs to know whether a recovery path requiring the foreground (a Wi-Fi
  /// specifier join, for instance) has any chance of succeeding.
  static bool get isForeground => _instance._foreground;
  bool _foreground = true;

  /// How long the app has been in the background, or [Duration.zero] while it
  /// is foreground.
  static Duration get backgroundedFor {
    final since = _instance._leftAt;
    if (since == null) return Duration.zero;
    return DateTime.now().difference(since);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    switch (state) {
      case AppLifecycleState.resumed:
        final away = _leftAt;
        _foreground = true;
        _leftAt = null;
        Logger.diagnostic(
          away == null
              ? 'lifecycle: resumed'
              : 'lifecycle: resumed after '
                    '${DateTime.now().difference(away).inMilliseconds}ms away',
        );
      case AppLifecycleState.inactive:
        // Deliberately not treated as leaving: `inactive` fires for a
        // notification shade pull or an incoming-call banner, neither of which
        // costs the app its foreground network scope. Recording it as a
        // departure would put a spurious "away for 300ms" in front of every
        // real one.
        Logger.diagnostic('lifecycle: inactive');
      case AppLifecycleState.paused ||
          AppLifecycleState.hidden ||
          AppLifecycleState.detached:
        _foreground = false;
        _leftAt ??= DateTime.now();
        Logger.diagnostic('lifecycle: ${state.name}');
        // The window in which the OS is most likely to kill us starts now.
        unawaited(DiagnosticLog.flush());
    }
  }
}
