import 'dart:async';

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../settings/settings_keys.dart';
import '../theme/theme_service.dart';
import '../utils/logger.dart';
import 'sfx_event.dart';

/// Eyes-free audio cues for every meaningful in-app event (PTT, peer
/// join/leave, link drop/recover, errors, toggles...) — the rider can't look
/// at the screen with the phone in a pocket, so every state change that
/// matters gets a distinct, short sound alongside whatever visual it already
/// has. Static/`ValueNotifier`-based singleton, same shape as [ThemeService]
/// and `LocaleService`, so no DI wiring is needed to use it from anywhere.
class Sfx {
  const Sfx._();

  static final enabled = ValueNotifier<bool>(true);
  static final Map<SfxEvent, AudioPlayer> _players = {};
  static late SharedPreferences _prefs;
  static bool _ready = false;

  /// [prefs] is the entrypoint's one process-wide SharedPreferences
  /// resolution — this service runs before (or without) DI, so it receives
  /// the instance instead of resolving its own.
  static Future<void> initialize(SharedPreferences prefs) async {
    _prefs = prefs;
    enabled.value = _prefs.getBool(SettingsKeys.sfxEnabled) ?? true;

    for (final event in SfxEvent.values) {
      final player = AudioPlayer(playerId: 'sfx_${event.name}');
      try {
        // Default (media-player) mode on purpose: it keeps the preloaded
        // source between plays with [ReleaseMode.stop] and — unlike
        // [PlayerMode.lowLatency] — reliably emits `seekComplete`, which the
        // rewind in [play] depends on. lowLatency also silently ignores the
        // release mode, so the two were contradictory before.
        await player.setReleaseMode(ReleaseMode.stop);
        await player.setSource(AssetSource(event.assetPath));
      } catch (e) {
        Logger.log('Sfx preload failed for ${event.name}: $e');
      }
      _players[event] = player;
    }
    _ready = true;
  }

  static Future<void> setEnabled(bool value) async {
    enabled.value = value;
    await _prefs.setBool(SettingsKeys.sfxEnabled, value);
  }

  /// Fire-and-forget: never awaited by callers, and a playback failure
  /// (missing codec, device silent-mode quirk, etc.) must never surface as
  /// an app error — it's a cosmetic cue, not a functional path.
  ///
  /// Each player is preloaded once and reused for the whole process, so we
  /// rewind to the start before every play: after a clip finishes, the native
  /// cursor sits at the end of the buffer (kept there by [ReleaseMode.stop]),
  /// and a bare `resume()` would resume from the end and play nothing — the
  /// same action would only ever be heard on its first trigger. Seeking to
  /// zero first makes every repeat of an action audible again.
  static void play(SfxEvent event) {
    if (!_ready || !enabled.value) return;
    final player = _players[event];
    if (player == null) return;
    unawaited(
      _replayFromStart(player).catchError((Object e) {
        Logger.log('Sfx playback failed for ${event.name}: $e');
      }),
    );
  }

  static Future<void> _replayFromStart(AudioPlayer player) async {
    await player.seek(Duration.zero);
    await player.resume();
  }

  static Future<void> dispose() async {
    for (final player in _players.values) {
      await player.dispose();
    }
    _players.clear();
    _ready = false;
  }
}
