import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:injectable/injectable.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../settings/settings_keys.dart';
import '../utils/logger.dart';
import 'entitlement.dart';
import 'entitlement_store.dart';
import 'trial_policy.dart';

@LazySingleton(as: EntitlementStore)
class EntitlementStoreImpl implements EntitlementStore {
  EntitlementStoreImpl(this._prefs) : _clock = DateTime.now;

  /// Movable clock, so the trial and its rollback guard are testable without
  /// waiting 90 days or touching the machine's date. Kept as a separate
  /// constructor rather than an optional parameter because injectable cannot
  /// resolve a bare function type in the one it generates a call to.
  @visibleForTesting
  EntitlementStoreImpl.withClock(this._prefs, this._clock);

  final SharedPreferences _prefs;
  final DateTime Function() _clock;
  final _controller = StreamController<Entitlement>.broadcast();

  Entitlement _current = const Entitlement.free();

  /// Highest wall-clock instant this install has ever seen, in epoch ms. Held
  /// in memory between launches' worth of writes so [now] stays cheap.
  int _highWaterMarkMs = 0;

  @override
  Entitlement get current => _current;

  @override
  bool get isPremiumActive => _current.isActiveAt(now);

  @override
  DateTime get now {
    final systemMs = _clock().millisecondsSinceEpoch;
    if (systemMs > _highWaterMarkMs) _highWaterMarkMs = systemMs;
    return DateTime.fromMillisecondsSinceEpoch(_highWaterMarkMs);
  }

  @override
  Stream<Entitlement> get changes => _controller.stream;

  @override
  Future<void> initialize() async {
    // Seed the water mark from disk *before* anything reads [now], so a
    // device whose date was wound back between launches is caught on this
    // very first evaluation rather than one screen later.
    _highWaterMarkMs = math.max(
      _prefs.getInt(SettingsKeys.clockHighWaterMark) ?? 0,
      _clock().millisecondsSinceEpoch,
    );
    await _prefs.setInt(SettingsKeys.clockHighWaterMark, _highWaterMarkMs);

    final source = EntitlementSource.fromKey(
      _prefs.getString(SettingsKeys.entitlementSource),
    );

    if (source == EntitlementSource.bazaar ||
        source == EntitlementSource.myket) {
      final expiryMs = _prefs.getInt(SettingsKeys.entitlementExpiresAt);
      _current = Entitlement(
        source: source,
        expiresAt: expiryMs == null
            ? null // lifetime purchase
            : DateTime.fromMillisecondsSinceEpoch(expiryMs),
      );
      return;
    }

    // No purchase on file: the trial is the only thing that can grant access.
    // Its clock starts on the first launch that ever reaches this line and is
    // never restarted — revoke() clears the purchase, not the trial stamp.
    var startedMs = _prefs.getInt(SettingsKeys.trialStartedAt);
    if (startedMs == null) {
      startedMs = _highWaterMarkMs;
      await _prefs.setInt(SettingsKeys.trialStartedAt, startedMs);
      Logger.log('Entitlement: trial started, ${TrialPolicy.length.inDays}d');
    }

    _current = Entitlement(
      source: EntitlementSource.trial,
      // Derived on every launch rather than persisted at trial start, so
      // shortening TrialPolicy.length applies to in-flight trials too. See
      // the note on TrialPolicy if that ever needs to change.
      expiresAt: DateTime.fromMillisecondsSinceEpoch(
        startedMs,
      ).add(TrialPolicy.length),
    );
  }

  @override
  Future<void> grant(Entitlement entitlement) async {
    _current = entitlement;
    await _prefs.setString(
      SettingsKeys.entitlementSource,
      entitlement.source.key,
    );
    final expiry = entitlement.expiresAt;
    if (expiry == null) {
      await _prefs.remove(SettingsKeys.entitlementExpiresAt);
    } else {
      await _prefs.setInt(
        SettingsKeys.entitlementExpiresAt,
        expiry.millisecondsSinceEpoch,
      );
    }
    Logger.log(
      'Entitlement: granted ${entitlement.source.key}'
      '${expiry == null ? ' (lifetime)' : ' until $expiry'}',
    );
    if (!_controller.isClosed) _controller.add(entitlement);
  }

  @override
  Future<void> revoke() async {
    _current = const Entitlement.free();
    await _prefs.remove(SettingsKeys.entitlementSource);
    await _prefs.remove(SettingsKeys.entitlementExpiresAt);
    // trialStartedAt survives deliberately — clearing it here would turn
    // every refund into a fresh 90-day trial.
    Logger.log('Entitlement: revoked, back to free tier');
    if (!_controller.isClosed) _controller.add(_current);
  }
}
