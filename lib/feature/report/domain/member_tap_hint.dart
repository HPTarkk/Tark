import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'report_config.dart';

/// Whether this phone still needs to learn that a rider can be tapped.
///
/// A row with a chevron or a "tap me" label on every rider would teach the
/// gesture forever to someone who needed it once. Instead the roster coaches
/// it once, on one rider, and stops for good as soon as a member card has
/// been opened or the coaching has had its moment on screen.
class MemberTapHint extends ChangeNotifier {
  MemberTapHint({Future<SharedPreferences> Function()? prefs})
    : _prefs = prefs ?? SharedPreferences.getInstance;

  /// The one the app uses.
  static final MemberTapHint instance = MemberTapHint();

  static const _storeKey = 'member_tap_hint.seen.v1';

  final Future<SharedPreferences> Function() _prefs;
  Future<void>? _loading;
  bool _loaded = false;
  bool _seen = false;

  /// Reads whether the hint was already learned. Until that read lands the
  /// hint stays hidden, so a returning rider never sees it flash.
  Future<void> load() => _loading ??= _load();

  Future<void> _load() async {
    try {
      _seen = (await _prefs()).getBool(_storeKey) ?? false;
    } catch (_) {
      // No storage: coach this session, forget it next launch.
    }
    _loaded = true;
    notifyListeners();
  }

  /// Whether the coaching should show right now.
  bool get showing => ReportConfig.enabled && _loaded && !_seen;

  /// The rider found the card, or had their chance to: never again.
  Future<void> learned() async {
    if (_seen) return;
    _seen = true;
    notifyListeners();
    try {
      await (await _prefs()).setBool(_storeKey, true);
    } catch (_) {
      // Stays learned for this session either way.
    }
  }

  @visibleForTesting
  void resetForTest() {
    _loading = null;
    _loaded = false;
    _seen = false;
  }
}
