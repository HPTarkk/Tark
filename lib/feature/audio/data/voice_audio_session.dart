import 'package:flutter/services.dart';

import '../../../core/utils/logger.dart';
import '../domain/entity/audio_route.dart';

/// Bridge to the native voice-session helpers (see
/// android/.../audio/AudioSessionHandler.kt and
/// ios/Runner/AudioSessionHandler.swift).
///
/// While a walkie session runs, the platform audio session is put into
/// phone-call mode: mic + playback follow the user's handsfree device
/// (AirPods, helmet headset, wired earphones) instead of sticking to the
/// built-in mic, and the OS applies its voice processing. Best-effort by
/// design — on platforms without the channel (desktop, web) or on any
/// native failure, audio simply keeps the default route.
abstract final class VoiceAudioSession {
  static const _channel = MethodChannel('tark/audio_session');
  static const _events = EventChannel('tark/audio_session/events');

  /// The longest a route choice can legitimately take on Android: the 4 s
  /// wait for Bluetooth SCO plus the 700 ms settle (AudioSessionHandler.kt),
  /// with room to spare.
  static const routingLimit = Duration(seconds: 8);

  /// Everything else here returns straight away.
  static const quickLimit = Duration(seconds: 3);

  /// Every call runs inside the audio engine's start/stop lock, so one reply
  /// that never arrives would leave the mic and speaker dead with no way back
  /// short of killing the app. Past [limit] the call is treated as failed,
  /// which every caller here already handles as "keep the default route".
  static Future<T?> _invoke<T>(
    String method,
    Duration limit, [
    Object? arguments,
  ]) {
    return _channel
        .invokeMethod<T>(method, arguments)
        .timeout(
          limit,
          onTimeout: () {
            Logger.diagnostic(
              'audio: $method got no reply in ${limit.inSeconds}s — '
              'carrying on without it',
            );
            return null;
          },
        );
  }

  /// Fires when a handsfree device is attached or detached while the session
  /// runs. The route is picked once, when the streams open, so without this
  /// a headset connected mid-session would be ignored — AudioEngineImpl
  /// re-opens the engine on every event.
  ///
  /// Silent on platforms without the channel: the broadcast stream reports a
  /// MissingPluginException there, which is dropped like any other failure
  /// in this class.
  static Stream<void> get routeChanges => _events
      .receiveBroadcastStream()
      .handleError(
        (Object e) => Logger.log('Voice audio route events unavailable: $e'),
      )
      .map((_) {});

  static Future<void> configure() async {
    try {
      await _invoke<void>('configureVoice', routingLimit);
    } catch (e) {
      Logger.log('Voice audio session configure failed: $e');
    }
  }

  /// Re-picks the output/input device for a session that is already in voice
  /// mode. Distinct from [configure], which no-ops once engaged and cannot
  /// undo an already-selected device.
  static Future<void> reconfigure() async {
    try {
      await _invoke<void>('reconfigureVoice', routingLimit);
    } catch (e) {
      Logger.log('Voice audio session reconfigure failed: $e');
    }
  }

  /// Android only: attaches the platform's AcousticEchoCanceler /
  /// NoiseSuppressor / AutomaticGainControl to the capture [sessionId] (from
  /// [AudioIo.inputSessionId]), making call-grade voice processing explicit
  /// rather than relying solely on the VOICE_COMMUNICATION input preset. A
  /// negative id (iOS, web, or an OpenSL fallback) is a no-op — those paths get
  /// their processing from the session preset / AVAudioSession voiceChat.
  static Future<void> attachEffects(int sessionId) async {
    if (sessionId < 0) return;
    try {
      await _invoke<void>('attachEffects', quickLimit, {
        'sessionId': sessionId,
      });
    } catch (e) {
      Logger.log('Voice audio effects attach failed: $e');
    }
  }

  static Future<void> release() async {
    try {
      await _invoke<void>('releaseVoice', quickLimit);
    } catch (e) {
      Logger.log('Voice audio session release failed: $e');
    }
  }

  /// What voice is actually routed through right now — Preflight's headset
  /// check (#33). Read-only: never engages call mode, safe to call whether
  /// or not a session has [configure]d voice yet. [AudioRoute.unknown] on any
  /// platform without this channel (all of iOS today — no Swift counterpart
  /// exists yet) or native failure; never treated as a failure by callers.
  static Future<AudioRoute> getCurrentRoute() async {
    try {
      final raw = await _invoke<String>('getCurrentRoute', quickLimit);
      return switch (raw) {
        'bluetooth' => AudioRoute.bluetoothHeadset,
        'wired' => AudioRoute.wired,
        'speaker' => AudioRoute.builtInSpeaker,
        _ => AudioRoute.unknown,
      };
    } catch (e) {
      Logger.log('Voice audio route query failed: $e');
      return AudioRoute.unknown;
    }
  }
}
