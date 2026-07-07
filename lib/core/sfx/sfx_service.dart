import 'dart:async';

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

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

  static const _prefsKey = 'sfx_enabled';

  static final enabled = ValueNotifier<bool>(true);
  static final Map<SfxEvent, AudioPlayer> _players = {};
  static bool _ready = false;

  static Future<void> initialize() async {
    final prefs = await SharedPreferences.getInstance();
    enabled.value = prefs.getBool(_prefsKey) ?? true;

    for (final event in SfxEvent.values) {
      final player = AudioPlayer(playerId: 'sfx_${event.name}');
      try {
        await player.setPlayerMode(PlayerMode.lowLatency);
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
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_prefsKey, value);
  }

  /// Fire-and-forget: never awaited by callers, and a playback failure
  /// (missing codec, device silent-mode quirk, etc.) must never surface as
  /// an app error — it's a cosmetic cue, not a functional path.
  static void play(SfxEvent event) {
    if (!_ready || !enabled.value) return;
    final player = _players[event];
    if (player == null) return;
    unawaited(player.resume().catchError((Object e) {
      Logger.log('Sfx playback failed for ${event.name}: $e');
    }));
  }

  static Future<void> dispose() async {
    for (final player in _players.values) {
      await player.dispose();
    }
    _players.clear();
    _ready = false;
  }
}
