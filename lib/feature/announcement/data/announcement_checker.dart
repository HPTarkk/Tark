import 'dart:io' show Platform;

import 'package:flutter/foundation.dart';
import 'package:injectable/injectable.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../../core/account/account_session.dart';
import '../../../core/entitlement/license_gate.dart';
import '../../../core/entitlement/premium_feature.dart';
import '../../../core/network/api_client.dart';
import '../../../core/settings/settings_keys.dart';
import '../../../core/utils/logger.dart';
import '../domain/entity/announcement.dart';

/// Asks the website what Tarkk has to say, and remembers what was said.
///
/// Like the update check there is no backend: the answer is a static file,
/// `announcements.json`, published with the website. Every way this can fail
/// ends in an empty list, and the app carries on as if it had never asked.
@lazySingleton
class AnnouncementChecker {
  AnnouncementChecker(this._api, this._prefs, this._session, this._license);

  final ApiClient _api;
  final SharedPreferences _prefs;
  final AccountSession _session;
  final LicenseGate _license;

  /// Overridable per build; an empty value compiles the check out:
  ///
  ///     flutter build apk --dart-define=TARK_ANNOUNCEMENTS_FEED=
  static const feedUrl = String.fromEnvironment(
    'TARK_ANNOUNCEMENTS_FEED',
    defaultValue: 'https://tarkk.ir/announcements.json',
  );

  static const _timeout = Duration(seconds: 8);

  /// Seen ids kept on the phone. Old ones fall off the front; an id that old
  /// has long since left the feed.
  static const _seenCap = 200;

  static bool get isSupported => feedUrl.isNotEmpty && !kIsWeb;

  Future<List<Announcement>> check() async {
    if (!isSupported) return const [];
    final base = Uri.tryParse(feedUrl);
    if (base == null) return const [];
    // A query nobody asked for before is always a cache miss, so a new
    // announcement is seen at once.
    final url = base.replace(
      queryParameters: {
        ...base.queryParameters,
        't': DateTime.now().millisecondsSinceEpoch.toString(),
      },
    );
    final result = await _api.getJson(
      url,
      timeout: _timeout,
      maxBytes: 64 * 1024,
    );
    final json = result.fold((failure) {
      Logger.log('Announcements: feed unavailable — ${failure.message}');
      return null;
    }, (json) => json);
    if (json == null) return const [];

    final AnnouncementFeed feed;
    try {
      feed = AnnouncementFeed.fromJson(json);
    } on AnnouncementFormatException catch (e) {
      Logger.log('Announcements: feed rejected — ${e.message}');
      return const [];
    }
    for (final reason in feed.rejected) {
      Logger.log('Announcements: entry dropped — $reason');
    }
    if (feed.announcements.isEmpty) return const [];

    final int build;
    try {
      build = int.parse((await PackageInfo.fromPlatform()).buildNumber);
    } catch (e) {
      Logger.log('Announcements: installed build unreadable — $e');
      return const [];
    }

    // Restored from storage without the network; harmless if already done.
    await _session.load();
    final monetized = _license.canPurchase;
    final picked = pickAnnouncements(
      feed,
      AnnouncementContext(
        now: DateTime.now().toUtc(),
        build: build,
        platform: Platform.isIOS ? 'ios' : 'android',
        seen: seen,
        signedIn: _session.isSignedIn,
        canSignIn: _session.available,
        monetized: monetized,
        premium: monetized && _license.allows(PremiumFeature.wifiTransport),
      ),
    );
    Logger.log(
      'Announcements: ${feed.announcements.length} in feed → '
      '${picked.isEmpty ? 'nothing new' : picked.map((a) => a.id).join(', ')}',
    );
    return picked;
  }

  Set<String> get seen =>
      (_prefs.getStringList(SettingsKeys.announcementsSeen) ?? const [])
          .toSet();

  /// [ids] were shown; they never come back.
  Future<void> markSeen(Iterable<String> ids) async {
    final list = _prefs.getStringList(SettingsKeys.announcementsSeen) ?? [];
    final known = list.toSet();
    var changed = false;
    for (final id in ids) {
      if (known.add(id)) {
        list.add(id);
        changed = true;
      }
    }
    if (!changed) return;
    final kept = list.length > _seenCap
        ? list.sublist(list.length - _seenCap)
        : list;
    await _prefs.setStringList(SettingsKeys.announcementsSeen, kept);
  }
}
