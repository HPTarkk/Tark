import 'package:flutter/foundation.dart';
import 'package:injectable/injectable.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../../core/network/api_client.dart';
import '../../../core/settings/settings_keys.dart';
import '../../../core/utils/logger.dart';
import '../domain/entity/update_feed.dart';

/// Asks the website whether a newer Android build is out.
///
/// There is no backend: the answer is a static file, `update.json`, published
/// with the website. Every way this can fail — no signal, the host down, a
/// typo in the file — ends in `null`, which the gate reads as "nothing to say"
/// and the app carries on as if it had never asked.
@lazySingleton
class UpdateChecker {
  UpdateChecker(this._api, this._prefs);

  final ApiClient _api;
  final SharedPreferences _prefs;

  /// Overridable per build; an empty value compiles the check out:
  ///
  ///     flutter build apk --dart-define=TARK_UPDATE_FEED=
  static const feedUrl = String.fromEnvironment(
    'TARK_UPDATE_FEED',
    defaultValue: 'https://tarkk.ir/update.json',
  );

  /// Short, because nothing waits on it — but a slow answer that arrives
  /// half a minute into a conversation would interrupt it.
  static const _timeout = Duration(seconds: 8);

  /// Only Android is distributed through a store this feed describes.
  static bool get isSupported =>
      feedUrl.isNotEmpty &&
      !kIsWeb &&
      defaultTargetPlatform == TargetPlatform.android;

  Future<UpdateOffer?> check() async {
    if (!isSupported) return null;
    final base = Uri.tryParse(feedUrl);
    if (base == null) return null;
    // Cloudflare and any proxy on the way may cache the file; a query no one
    // has asked for before is always a miss, so a release is seen at once.
    final url = base.replace(
      queryParameters: {
        ...base.queryParameters,
        't': DateTime.now().millisecondsSinceEpoch.toString(),
      },
    );
    final result = await _api.getJson(
      url,
      timeout: _timeout,
      maxBytes: 32 * 1024,
    );
    final json = result.fold((failure) {
      Logger.log('Update: feed unavailable — ${failure.message}');
      return null;
    }, (json) => json);
    if (json == null) return null;

    final UpdateFeed feed;
    try {
      feed = UpdateFeed.fromJson(json);
    } on UpdateFeedException catch (e) {
      Logger.log('Update: feed rejected — ${e.message}');
      return null;
    }

    final int installed;
    final String installedVersion;
    try {
      final info = await PackageInfo.fromPlatform();
      installed = int.parse(info.buildNumber);
      installedVersion = info.version;
    } catch (e) {
      Logger.log('Update: installed build unreadable — $e');
      return null;
    }

    final snoozedAt = _prefs.getInt(SettingsKeys.updateSnoozedAt);
    final offer = decideUpdate(
      feed: feed,
      installedBuild: installed,
      installedVersion: installedVersion,
      now: DateTime.now(),
      snoozedBuild: _prefs.getInt(SettingsKeys.updateSnoozedBuild),
      snoozedAt: snoozedAt == null
          ? null
          : DateTime.fromMillisecondsSinceEpoch(snoozedAt),
    );
    Logger.log(
      'Update: installed $installed, latest ${feed.latestBuild}, '
      'minimum ${feed.minimumBuild} → ${offer?.urgency.name ?? 'nothing'}',
    );
    return offer;
  }

  /// The user put off [offer]; it stays quiet for a while (see decideUpdate).
  Future<void> snooze(UpdateOffer offer) async {
    await _prefs.setInt(
      SettingsKeys.updateSnoozedBuild,
      offer.feed.latestBuild,
    );
    await _prefs.setInt(
      SettingsKeys.updateSnoozedAt,
      DateTime.now().millisecondsSinceEpoch,
    );
  }
}
