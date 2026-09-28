import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/foundation.dart' show visibleForTesting;

import '../security/app_secure_storage.dart';
import '../utils/logger.dart';
import 'install_identity.dart';
import 'signed_entitlement.dart';
import 'subscription_policy.dart';
import 'subscription_remote.dart';

/// Where a premium tap lands once the rules and, if needed, the server have
/// had their say. Every case is its own screen.
sealed class GateOutcome {
  const GateOutcome();
}

/// Premium is unlocked; carry on with what was tapped.
class GateGranted extends GateOutcome {
  const GateGranted();
}

/// The server was reached and there is no running subscription: the plain
/// subscribe / renew screen. Not an error.
class GateSubscribe extends GateOutcome {
  const GateSubscribe({this.endedAt});

  /// When the last subscription ended, if there was one — lets the renewal
  /// screen say "welcome back" instead of pitching from scratch.
  final DateTime? endedAt;
}

/// The server could not be reached, so the rules decide which of the three
/// "couldn't check" screens to show.
class GateCouldNotCheck extends GateOutcome {
  const GateCouldNotCheck({
    required this.reason,
    required this.serviceTrouble,
    this.endedAt,
    this.lastCheckedAt,
  });

  final CheckReason reason;

  /// True when the phone *was* online but our side could not answer — the
  /// copy must not tell this person to go find internet.
  final bool serviceTrouble;

  /// Last known end of the subscription, for [CheckReason.expired].
  final DateTime? endedAt;

  /// Last successful check, for [CheckReason.staleCheck].
  final DateTime? lastCheckedAt;
}

/// A subscription needs an account and this install has none signed in.
class GateSignInRequired extends GateOutcome {
  const GateSignInRequired();
}

/// The purchase is tied to a different account.
class GatePurchaseOwnedElsewhere extends GateOutcome {
  const GatePurchaseOwnedElsewhere();
}

/// The one owner of subscription state on this phone.
///
/// State lives in secure storage as the server's signed token plus two
/// clock numbers, and nowhere else. Access is always the pure
/// [SubscriptionPolicy] applied to the verified token and [now], so the gate
/// and the screens cannot disagree.
class SubscriptionService {
  SubscriptionService({
    required AppSecureStorage storage,
    required InstallIdentity identity,
    required EntitlementVerifier verifier,
    required SubscriptionRemote remote,
    required bool monetized,
    DateTime Function()? clock,
  }) : _storage = storage,
       _identity = identity,
       _verifier = verifier,
       _remote = remote,
       _monetized = monetized,
       _clock = clock ?? DateTime.now;

  final AppSecureStorage _storage;
  final InstallIdentity _identity;
  final EntitlementVerifier _verifier;
  final SubscriptionRemote _remote;
  final bool _monetized;
  final DateTime Function() _clock;
  final _changes = StreamController<void>.broadcast();

  static const _storageKey = 'subscription_state';

  SignedEntitlement? _token;

  /// Server time minus device time at the last successful check. Adding it
  /// to the device clock gives server-relative time, so a phone whose clock
  /// is simply wrong is judged by the right date, not punished for it.
  int _skewMs = 0;

  /// Highest server-relative instant this install has seen. Winding the
  /// device clock back moves the corrected clock back too; this does not
  /// move, so it buys nothing.
  int _highWaterMs = 0;

  /// Water mark as last written to storage; see [now].
  int _persistedHighWaterMs = 0;

  /// How far the water mark may run ahead of storage before it is written
  /// again. Without this, an app left open for a week and then killed would
  /// relaunch with last week's mark, and winding the clock back in between
  /// would win back that week.
  static const _persistStepMs = 60 * 60 * 1000;

  Future<SubscriptionFetch>? _inFlight;

  /// The verified token, or null when there is none (or it did not verify).
  SignedEntitlement? get entitlement => _token;

  /// Fires whenever access may have changed, so a screen showing a gated
  /// control can re-read [isPremiumActive].
  Stream<void> get changes => _changes.stream;

  /// Trustworthy "now": server-relative, and never earlier than anything
  /// already seen.
  DateTime get now {
    final corrected = _clock().millisecondsSinceEpoch + _skewMs;
    _highWaterMs = math.max(_highWaterMs, corrected);
    if (_monetized && _highWaterMs - _persistedHighWaterMs > _persistStepMs) {
      _persistedHighWaterMs = _highWaterMs;
      unawaited(_persist());
    }
    return DateTime.fromMillisecondsSinceEpoch(_highWaterMs, isUtc: true);
  }

  SubscriptionAccess get access => SubscriptionPolicy.evaluate(_token, now);

  bool get isPremiumActive => access is AccessGranted;

  /// Loads and verifies the stored token. Must finish before the first
  /// frame, like the old EntitlementStore, so gates can be read synchronously.
  /// Starts a quiet background refresh when the rules ask for one.
  Future<void> initialize() async {
    if (!_monetized) return;
    await _identity.load();
    await _load();
    await _persist();

    // Only accounts that have subscribed are refreshed at launch: a free
    // user who never tapped a paid feature has nothing to refresh, and
    // their phone should not be calling home on every start.
    final current = access;
    final hasHistory =
        _token != null && _token!.status != EntitlementStatus.none;
    final wantsRefresh = switch (current) {
      AccessGranted(:final refreshSuggested) => refreshSuggested,
      AccessNeedsCheck() => true,
    };
    if (hasHistory && wantsRefresh) unawaited(_refresh());
  }

  /// Called when a paid feature is tapped and [isPremiumActive] is false.
  /// Asks the server once, then says which screen to show.
  Future<GateOutcome> check() async {
    if (isPremiumActive) return const GateGranted();
    return _outcomeFor(await _refresh());
  }

  /// Hands a fresh Bazaar purchase to the server. The server verifies it with
  /// Bazaar itself; this phone's word about the purchase counts for nothing.
  Future<GateOutcome> submitBazaarPurchase({
    required String sku,
    required String purchaseToken,
  }) async {
    final fetch = await _remote.submitBazaarPurchase(
      installKey: _identity.publicKey,
      sku: sku,
      purchaseToken: purchaseToken,
    );
    return _outcomeFor(await _accept(fetch));
  }

  /// Drops local subscription state, e.g. on sign-out. The next paid tap
  /// checks with the server again.
  Future<void> clear() async {
    _token = null;
    await _storage.delete(_storageKey);
    _notify();
  }

  GateOutcome _outcomeFor(SubscriptionFetch fetch) {
    final current = access;
    if (current is AccessGranted) return const GateGranted();
    final reason = (current as AccessNeedsCheck).reason;
    return switch (fetch) {
      FetchedEntitlement() => GateSubscribe(
        endedAt: reason == CheckReason.noData ? null : _token?.until,
      ),
      FetchSignedOut() => const GateSignInRequired(),
      FetchPurchaseOwnedElsewhere() => const GatePurchaseOwnedElsewhere(),
      FetchUnreachable() || FetchServiceTrouble() => GateCouldNotCheck(
        reason: reason,
        serviceTrouble: fetch is FetchServiceTrouble,
        endedAt: _token?.until,
        lastCheckedAt: _token?.issuedAt,
      ),
    };
  }

  /// One request at a time: a launch refresh and a tap landing together
  /// share the same answer instead of racing to write it.
  Future<SubscriptionFetch> _refresh() {
    return _inFlight ??= () async {
      try {
        final fetch = await _remote.fetch(installKey: _identity.publicKey);
        return await _accept(fetch);
      } finally {
        _inFlight = null;
      }
    }();
  }

  Future<SubscriptionFetch> _accept(SubscriptionFetch fetch) async {
    if (fetch is! FetchedEntitlement) {
      if (fetch is FetchSignedOut && _token != null) {
        // The account behind the stored token is gone from this phone.
        await clear();
      }
      return fetch;
    }
    final verified = await _verifier.verify(
      fetch.token,
      expectedInstallKey: _identity.publicKey,
    );
    if (verified == null) {
      // A reply we cannot verify is treated as no reply at all.
      Logger.diagnostic('Subscription: server token failed verification');
      return const FetchServiceTrouble();
    }
    _token = verified;
    final deviceMs = _clock().millisecondsSinceEpoch;
    final serverMs = verified.issuedAt.millisecondsSinceEpoch;
    _skewMs = serverMs - deviceMs;
    // The server's clock is the truth: reset rather than max, so a phone
    // whose clock once ran far ahead is not stuck in its own future.
    _highWaterMs = serverMs;
    await _persist();
    Logger.log(
      'Subscription: ${verified.status.name}'
      '${verified.suspicious ? ' (conservative)' : ''}'
      '${fetch.bazaarChecked ? '' : ', Bazaar not re-checked'}',
    );
    _notify();
    return fetch;
  }

  Future<void> _load() async {
    String? raw;
    try {
      raw = await _storage.read(_storageKey);
    } catch (error) {
      Logger.log('Subscription: stored state unreadable ($error)');
    }
    if (raw == null) return;
    try {
      final json = jsonDecode(raw) as Map<String, dynamic>;
      final token = json['t'] as String?;
      _skewMs = json['s'] as int? ?? 0;
      _highWaterMs = json['h'] as int? ?? 0;
      if (token != null) {
        _token = await _verifier.verify(
          token,
          expectedInstallKey: _identity.publicKey,
        );
        if (_token == null) {
          Logger.log('Subscription: stored token no longer verifies');
        } else {
          // The token's issue time is a floor the clock can never go below.
          _highWaterMs = math.max(
            _highWaterMs,
            _token!.issuedAt.millisecondsSinceEpoch,
          );
        }
      }
    } catch (error) {
      Logger.log('Subscription: stored state malformed ($error)');
      _token = null;
    }
  }

  Future<void> _persist() async {
    // Advance the water mark before writing it — inline rather than through
    // [now], which would schedule a second write of the same value.
    _highWaterMs = math.max(
      _highWaterMs,
      _clock().millisecondsSinceEpoch + _skewMs,
    );
    _persistedHighWaterMs = _highWaterMs;
    try {
      await _storage.write(
        _storageKey,
        jsonEncode({'t': _token?.raw, 's': _skewMs, 'h': _highWaterMs}),
      );
    } catch (error) {
      Logger.log('Subscription: could not persist state ($error)');
    }
  }

  void _notify() {
    if (!_changes.isClosed) _changes.add(null);
  }

  @visibleForTesting
  Future<void> dispose() => _changes.close();
}
