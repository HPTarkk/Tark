import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:flutter/services.dart';

import '../utils/logger.dart';

/// The Dart half of the Android freeze watchdog (FreezeWatchdog.kt).
///
/// While the app is in the foreground this beats once a second. The native
/// side watches the beat from a thread of its own: when it stops for five
/// seconds the Dart isolate is stuck (no ANR ever fires for that — the
/// platform thread is still answering), and when the run dies in that state
/// the next start says so. Freezes that recovered come back on a later beat
/// and go into the log as they happened.
///
/// Paused while the app is in the background, where a slow timer is the
/// operating system's choice rather than a freeze.
abstract final class FreezeWatch {
  static const _channel = MethodChannel('tark/diagnostics/watchdog');
  static const interval = Duration(seconds: 1);

  static Timer? _timer;
  static bool _beating = false;

  @visibleForTesting
  static bool enabled = Platform.isAndroid;

  /// Foreground: start beating (idempotent).
  static void resume() {
    if (!enabled || _timer != null) return;
    unawaited(_beat('heartbeat'));
    _timer = Timer.periodic(interval, (_) => unawaited(_beat('heartbeat')));
  }

  /// Background: stop, and tell the watchdog the silence is on purpose.
  static void pause() {
    if (!enabled) return;
    _timer?.cancel();
    _timer = null;
    unawaited(_beat('pause'));
  }

  static Future<void> _beat(String method) async {
    // One call in flight at a time: beats queued behind a slow platform
    // would only arrive together and say nothing.
    if (_beating && method == 'heartbeat') return;
    _beating = true;
    try {
      final recovered = await _channel.invokeListMethod<String>(method);
      for (final line in recovered ?? const <String>[]) {
        Logger.diagnostic('app: $line');
      }
    } catch (_) {
      // Diagnostics must never be what takes a session down.
    } finally {
      _beating = false;
    }
  }

  /// Lines for the log describing the freeze the previous run died in, from
  /// the watchdog's note (`thread=main frozenForMs=…` and its frames).
  static List<String> describeLeftover(String note) {
    final lines = note.split('\n').where((l) => l.trim().isNotEmpty).toList();
    if (lines.isEmpty) return const [];
    final head = RegExp(
      r'thread=(\w+) frozenForMs=(\d+)',
    ).firstMatch(lines.first);
    final which = head?.group(1) ?? 'unknown';
    final ms = int.tryParse(head?.group(2) ?? '');
    final seconds = ms == null ? '?' : (ms / 1000).toStringAsFixed(1);
    return [
      'app: previous run was frozen when it ended '
          'thread=$which frozenFor=${seconds}s',
      for (final line in lines.skip(1)) 'app:   ${line.trim()}',
    ];
  }
}
