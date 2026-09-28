/// What `tarkk.ir/update.json` says about the newest Android build.
///
/// The file is static and hand-edited on the website, so parsing is strict:
/// anything that does not look exactly right throws [UpdateFeedException], and
/// a feed that cannot be trusted is treated the same as no feed at all — the
/// app carries on.
///
/// ```json
/// {
///   "android": {
///     "latestVersion": "1.0.22",
///     "latestBuild": 32,
///     "minimumBuild": 0,
///     "url": "https://cafebazaar.ir/app/com.b1101.tark",
///     "notes": { "en": ["..."], "fa": ["..."] }
///   }
/// }
/// ```
///
/// Builds, not version names, decide everything: the build number is the one
/// value a store guarantees only ever rises.
class UpdateFeed {
  const UpdateFeed({
    required this.latestVersion,
    required this.latestBuild,
    required this.minimumBuild,
    required this.url,
    required this.notes,
  });

  /// Shown to people; never compared.
  final String latestVersion;
  final int latestBuild;

  /// Anything older than this has to update before it can be used.
  final int minimumBuild;

  /// Where the Update button goes when the store app cannot be opened.
  final Uri url;

  /// Release notes by language code. Either list may be empty.
  final Map<String, List<String>> notes;

  factory UpdateFeed.fromJson(Map<String, dynamic> json) {
    final android = json['android'];
    if (android is! Map<String, dynamic>) {
      throw const UpdateFeedException('no "android" object');
    }
    final latestVersion = android['latestVersion'];
    final latestBuild = android['latestBuild'];
    final minimumBuild = android['minimumBuild'] ?? 0;
    final url = Uri.tryParse(android['url'] as String? ?? '');
    if (latestVersion is! String || latestVersion.isEmpty) {
      throw const UpdateFeedException('"latestVersion" missing');
    }
    if (latestBuild is! int || latestBuild < 1) {
      throw const UpdateFeedException('"latestBuild" must be a positive int');
    }
    if (minimumBuild is! int || minimumBuild > latestBuild) {
      // A minimum above the latest would demand an update nobody can get.
      throw const UpdateFeedException(
        '"minimumBuild" must be an int no higher than "latestBuild"',
      );
    }
    if (url == null || url.scheme != 'https') {
      throw const UpdateFeedException('"url" must be an https URL');
    }
    final notes = <String, List<String>>{};
    final rawNotes = android['notes'];
    if (rawNotes is Map<String, dynamic>) {
      for (final entry in rawNotes.entries) {
        final lines = entry.value;
        if (lines is List) {
          notes[entry.key] = [
            for (final line in lines)
              if (line is String && line.trim().isNotEmpty) line.trim(),
          ];
        }
      }
    }
    return UpdateFeed(
      latestVersion: latestVersion,
      latestBuild: latestBuild,
      minimumBuild: minimumBuild,
      url: url,
      notes: notes,
    );
  }

  /// Notes in [languageCode], falling back to English, then to none.
  List<String> notesFor(String languageCode) =>
      notes[languageCode] ?? notes['en'] ?? const [];
}

class UpdateFeedException implements Exception {
  const UpdateFeedException(this.message);
  final String message;

  @override
  String toString() => 'UpdateFeedException: $message';
}

/// How insistent the prompt is.
enum UpdateUrgency {
  /// The user can put it off.
  optional,

  /// The installed build is below the feed's minimum; the app stops here.
  required,
}

/// An update worth telling the user about.
class UpdateOffer {
  const UpdateOffer({
    required this.feed,
    required this.urgency,
    this.installedVersion = '',
  });

  final UpdateFeed feed;
  final UpdateUrgency urgency;

  /// The version name running now, for the "from → to" line. May be empty.
  final String installedVersion;
}

/// Decides whether [installedBuild] should be told about [feed].
///
/// [snoozedBuild] and [snoozedAt] record the last optional prompt the user put
/// off: that same build stays quiet for [snooze], and a newer one asks again at
/// once. Nothing snoozes a required update.
UpdateOffer? decideUpdate({
  required UpdateFeed feed,
  required int installedBuild,
  required DateTime now,
  String installedVersion = '',
  int? snoozedBuild,
  DateTime? snoozedAt,
  Duration snooze = const Duration(days: 3),
}) {
  if (installedBuild < feed.minimumBuild) {
    return UpdateOffer(
      feed: feed,
      urgency: UpdateUrgency.required,
      installedVersion: installedVersion,
    );
  }
  if (installedBuild >= feed.latestBuild) return null;
  final snoozed =
      snoozedBuild == feed.latestBuild &&
      snoozedAt != null &&
      now.difference(snoozedAt) < snooze;
  if (snoozed) return null;
  return UpdateOffer(
    feed: feed,
    urgency: UpdateUrgency.optional,
    installedVersion: installedVersion,
  );
}
