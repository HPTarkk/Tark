import '../utils/logger.dart';

/// Lightweight, privacy-safe counters/timers for the live voice path.
///
/// This intentionally logs only transport/audio health metadata — never audio
/// samples, tokens, invite payloads, contact data, or user-entered content.
abstract final class VoiceMetrics {
  static final Map<String, int> _counters = <String, int>{};
  static DateTime? _lastReconnectStartedAt;
  static DateTime? _lastTransportSwitchStartedAt;

  static void increment(String name, [int by = 1]) {
    final value = (_counters[name] ?? 0) + by;
    _counters[name] = value;
    Logger.log('[metrics] counter.$name=$value');
  }

  static void gauge(String name, Object value) {
    Logger.log('[metrics] gauge.$name=$value');
  }

  static Stopwatch startTimer(String name) {
    Logger.log('[metrics] timer.$name.start');
    return Stopwatch()..start();
  }

  static void stopTimer(String name, Stopwatch timer) {
    timer.stop();
    Logger.log('[metrics] timer.$name.ms=${timer.elapsedMilliseconds}');
  }

  static void connectionHealth(String transport, String health) {
    gauge('current_network_transport', transport);
    gauge('connection_health', health);
    if (health == 'reconnecting') {
      increment('reconnect_count');
      _lastReconnectStartedAt = DateTime.now();
    } else if (health == 'healthy') {
      final started = _lastReconnectStartedAt;
      if (started != null) {
        gauge(
          'reconnect_duration_ms',
          DateTime.now().difference(started).inMilliseconds,
        );
        _lastReconnectStartedAt = null;
      }
      final switchStarted = _lastTransportSwitchStartedAt;
      if (switchStarted != null) {
        gauge(
          'transport_switch_duration_ms',
          DateTime.now().difference(switchStarted).inMilliseconds,
        );
        _lastTransportSwitchStartedAt = null;
      }
    }
  }

  static void markTransportSwitch() {
    _lastTransportSwitchStartedAt = DateTime.now();
  }
}
