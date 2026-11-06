import 'dart:io' show Platform;

import 'package:flutter/foundation.dart';
import 'package:get_it/get_it.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../../core/utils/logger.dart';

/// When Tarkk may ask, on its own, for a rating on Cafe Bazaar.
///
/// The ask is a gift we hope for, so the rules are all about restraint:
///
/// * **Only after a good ride.** A ride counts when you shared the channel
///   with at least one other rider for [goodRide]. The ask comes as you get
///   back home from one, never in the middle of a channel, never at a cold
///   start, never on top of another prompt.
/// * **Only once Tarkk has earned it**: [ridesBeforeAsk] good rides since the
///   last ask, and at least [settleIn] since Tarkk first saw this phone.
/// * **Rarely, and never again once answered.** At most [maxAsks] times, at
///   least [cooldown] apart. Opening Bazaar from the story ends it for good:
///   we cannot tell whether the rating was posted, and asking someone who did
///   is worse than not asking someone who didn't.
///
/// Settings always has the row, so anyone can rate whenever they like.
class RatingPrompt {
  RatingPrompt(this._prefs, {DateTime Function()? clock})
    : _clock = clock ?? DateTime.now;

  final SharedPreferences _prefs;
  final DateTime Function() _clock;

  static const goodRide = Duration(minutes: 5);
  static const ridesBeforeAsk = 2;
  static const settleIn = Duration(days: 3);
  static const cooldown = Duration(days: 30);
  static const maxAsks = 3;

  static const _firstSeenKey = 'rating.first_seen_at';
  static const _ridesKey = 'rating.good_rides';
  static const _asksKey = 'rating.asks';
  static const _lastAskKey = 'rating.last_ask_at';
  static const _openedKey = 'rating.opened_at';

  /// The app's instance, or null before SharedPreferences is registered (a
  /// test that never set it up).
  static RatingPrompt? get registered {
    final getIt = GetIt.instance;
    if (getIt.isRegistered<RatingPrompt>()) return getIt<RatingPrompt>();
    if (!getIt.isRegistered<SharedPreferences>()) return null;
    final prompt = RatingPrompt(getIt<SharedPreferences>());
    getIt.registerSingleton<RatingPrompt>(prompt);
    return prompt;
  }

  /// Only Android phones have Bazaar to rate in.
  @visibleForTesting
  static bool? platformOverride;

  static bool get platformSupported =>
      platformOverride ?? (!kIsWeb && Platform.isAndroid);

  /// Set when the ride just left was a good one, for Home to pick up on
  /// arrival. In memory on purpose: the moment is "you just got back", and a
  /// restart is no longer that moment.
  bool _justRodeWell = false;

  /// Notes the first time Tarkk sees this phone. Safe to call every launch.
  Future<void> noteLaunch() async {
    if (_prefs.containsKey(_firstSeenKey)) return;
    await _write(() => _prefs.setInt(_firstSeenKey, _now));
  }

  /// A channel just ended, after [together] spent with other riders in it.
  Future<void> recordRide(Duration together) async {
    if (together < goodRide) return;
    _justRodeWell = true;
    await noteLaunch();
    await _write(
      () => _prefs.setInt(_ridesKey, (_prefs.getInt(_ridesKey) ?? 0) + 1),
    );
  }

  /// Whether to ask right now, on arriving home. Consumes the "just rode"
  /// moment either way, so a later visit to Home never asks about it.
  bool takeAskMoment() {
    final moment = _justRodeWell;
    _justRodeWell = false;
    return moment && eligible;
  }

  /// The rules above, minus the moment itself.
  bool get eligible {
    if (!platformSupported) return false;
    if (_prefs.containsKey(_openedKey)) return false;
    final asks = _prefs.getInt(_asksKey) ?? 0;
    if (asks >= maxAsks) return false;
    if ((_prefs.getInt(_ridesKey) ?? 0) < ridesBeforeAsk) return false;
    final now = _clock();
    final firstSeen = _prefs.getInt(_firstSeenKey);
    if (firstSeen == null ||
        now.difference(DateTime.fromMillisecondsSinceEpoch(firstSeen)) <
            settleIn) {
      return false;
    }
    final lastAsk = _prefs.getInt(_lastAskKey);
    if (lastAsk != null &&
        now.difference(DateTime.fromMillisecondsSinceEpoch(lastAsk)) <
            cooldown) {
      return false;
    }
    return true;
  }

  /// The story was put up on Tarkk's own initiative.
  Future<void> recordAsked() => _write(() async {
    await _prefs.setInt(_asksKey, (_prefs.getInt(_asksKey) ?? 0) + 1);
    await _prefs.setInt(_lastAskKey, _now);
    // The next ask needs good rides of its own.
    await _prefs.setInt(_ridesKey, 0);
  });

  /// Bazaar's rating page (or the listing) opened from the story.
  Future<void> recordOpened() => _write(() => _prefs.setInt(_openedKey, _now));

  /// Whether this phone has already been to Bazaar from the story.
  bool get opened => _prefs.containsKey(_openedKey);

  int get _now => _clock().millisecondsSinceEpoch;

  Future<void> _write(Future<void> Function() write) async {
    try {
      await write();
    } catch (e) {
      Logger.diagnostic('rating prompt: could not save — $e');
    }
  }
}

/// Measures how long a channel had company in it: the clock runs only while
/// at least one other rider is there.
class RideCompanyClock {
  RideCompanyClock({Stopwatch? stopwatch}) : _watch = stopwatch ?? Stopwatch();

  final Stopwatch _watch;

  void update({required int others}) {
    if (others > 0) {
      if (!_watch.isRunning) _watch.start();
    } else if (_watch.isRunning) {
      _watch.stop();
    }
  }

  Duration get together => _watch.elapsed;

  void stop() => _watch.stop();
}
