/// What `tarkk.ir/announcements.json` says the app should tell people.
///
/// Like the update feed, the file is static and hand-edited on the website
/// (see docs/announcements.md). Unlike it, one bad entry does not sink the
/// rest: each announcement is checked on its own, a broken one is dropped and
/// named in the log, and the others still go out. Only a file that is not an
/// announcements feed at all is thrown away whole.
///
/// ```json
/// {
///   "announcements": [
///     {
///       "id": "signup-gift-2026-11",
///       "category": "gift",
///       "title": { "en": "Three months on us", "fa": "سه ماه مهمان ما" },
///       "body": { "en": "…", "fa": "…" },
///       "highlight": { "en": "3 months free", "fa": "۳ ماه رایگان" },
///       "action": { "type": "signIn", "label": { "en": "Sign up", "fa": "ثبت‌نام" } },
///       "audience": "signedOut",
///       "startsAt": "2026-11-05T00:00:00Z",
///       "endsAt": "2026-12-05T00:00:00Z"
///     }
///   ]
/// }
/// ```
library;

/// The kind of news an announcement carries. Each one has its own emblem,
/// colour and arrival, so people learn to read the kind before the words.
enum AnnouncementCategory {
  /// A present: a free period, an offer. The box drops in and bursts open.
  gift,

  /// Something new in Tarkk. A spark ignites and throws its rays.
  feature,

  /// General word from the team. The mast powers on and broadcasts.
  news,

  /// A way to get more out of Tarkk. The bulb flickers on.
  tip,

  /// Something with a date. The calendar page flips down.
  event,

  /// Something people need to know now (service work, a known problem).
  /// The beacon swings in and sounds.
  alert;

  static AnnouncementCategory? parse(Object? raw) {
    for (final c in values) {
      if (c.name == raw) return c;
    }
    return null;
  }
}

/// Who an announcement is for. Announcements whose audience this phone is not
/// in are never shown, so a sign-up offer never reaches someone signed in.
enum AnnouncementAudience {
  everyone,

  /// No account on this phone — and a build where signing in is possible.
  signedOut,
  signedIn,

  /// No active subscription, on a build that sells one.
  free,

  /// An active subscription.
  premium;

  static AnnouncementAudience? parse(Object? raw) {
    if (raw == null) return everyone;
    for (final a in values) {
      if (a.name == raw) return a;
    }
    return null;
  }
}

/// What the primary button does.
enum AnnouncementActionType {
  /// Opens sign-in / sign-up.
  signIn,

  /// Opens an https page outside the app.
  link,

  /// Opens a screen inside the app, from a short allow-list (see
  /// [AnnouncementAction.routes]).
  screen;

  static AnnouncementActionType? parse(Object? raw) {
    for (final t in values) {
      if (t.name == raw) return t;
    }
    return null;
  }
}

/// Text in each language the feed wrote it in.
class LocalizedText {
  const LocalizedText(this.byLanguage);

  final Map<String, String> byLanguage;

  bool get isEmpty => byLanguage.isEmpty;

  /// [languageCode] if written, then English, then whatever there is.
  String of(String languageCode) =>
      byLanguage[languageCode] ??
      byLanguage['en'] ??
      (byLanguage.isEmpty ? '' : byLanguage.values.first);

  /// A plain string is taken as the English text; a map as text per language.
  /// Blank entries are left out. Throws on anything else.
  static LocalizedText parse(
    Object? raw,
    String field, {
    bool required = true,
  }) {
    final out = <String, String>{};
    if (raw is String) {
      if (raw.trim().isNotEmpty) out['en'] = raw.trim();
    } else if (raw is Map) {
      for (final entry in raw.entries) {
        final value = entry.value;
        if (entry.key is! String || value is! String) {
          throw AnnouncementFormatException(
            '"$field" must map languages to text',
          );
        }
        if (value.trim().isNotEmpty) out[entry.key as String] = value.trim();
      }
    } else if (raw != null) {
      throw AnnouncementFormatException(
        '"$field" must be text or a language map',
      );
    }
    if (required && out.isEmpty) {
      throw AnnouncementFormatException('"$field" is missing');
    }
    return LocalizedText(out);
  }
}

class AnnouncementAction {
  const AnnouncementAction({
    required this.type,
    required this.label,
    this.url,
    this.screen,
  });

  final AnnouncementActionType type;

  /// Empty means the app's own label for [type].
  final LocalizedText label;

  /// For [AnnouncementActionType.link].
  final Uri? url;

  /// For [AnnouncementActionType.screen]: one of [routes]' keys.
  final String? screen;

  /// The screens an announcement may open. A short list on purpose: the feed
  /// is public, so it can only point at places that make sense to land on
  /// cold, from the home screen.
  static const routes = {'settings', 'profile', 'rooms', 'advanced'};

  static AnnouncementAction? parse(Object? raw) {
    if (raw == null) return null;
    if (raw is! Map) {
      throw const AnnouncementFormatException('"action" must be an object');
    }
    final type = AnnouncementActionType.parse(raw['type']);
    if (type == null) {
      throw AnnouncementFormatException(
        '"action.type" must be one of '
        '${AnnouncementActionType.values.map((t) => t.name).join(', ')}',
      );
    }
    final label = LocalizedText.parse(
      raw['label'],
      'action.label',
      required: false,
    );
    switch (type) {
      case AnnouncementActionType.signIn:
        return AnnouncementAction(type: type, label: label);
      case AnnouncementActionType.link:
        final url = Uri.tryParse(raw['url'] as String? ?? '');
        if (url == null || url.scheme != 'https' || url.host.isEmpty) {
          throw const AnnouncementFormatException(
            '"action.url" must be an https URL',
          );
        }
        return AnnouncementAction(type: type, label: label, url: url);
      case AnnouncementActionType.screen:
        final screen = raw['screen'];
        if (screen is! String || !routes.contains(screen)) {
          throw AnnouncementFormatException(
            '"action.screen" must be one of ${routes.join(', ')}',
          );
        }
        return AnnouncementAction(type: type, label: label, screen: screen);
    }
  }
}

class Announcement {
  const Announcement({
    required this.id,
    required this.category,
    required this.title,
    required this.body,
    this.highlight = const LocalizedText({}),
    this.action,
    this.audience = AnnouncementAudience.everyone,
    this.startsAt,
    this.endsAt,
    this.minBuild = 0,
    this.maxBuild,
    this.platforms = const {},
    this.priority = 0,
  });

  /// Permanent: once someone has seen [id] they never see it again, so a
  /// changed announcement that should be shown again needs a new id.
  final String id;
  final AnnouncementCategory category;
  final LocalizedText title;
  final LocalizedText body;

  /// A short line set apart on a ticket ("3 months free"). Optional.
  final LocalizedText highlight;

  /// Absent: the announcement only says something, and its button is "Got it".
  final AnnouncementAction? action;
  final AnnouncementAudience audience;
  final DateTime? startsAt;
  final DateTime? endsAt;
  final int minBuild;
  final int? maxBuild;

  /// Empty means every platform the app runs on (but never the web guest).
  final Set<String> platforms;

  /// Higher goes first. Ties: the one that started most recently.
  final int priority;

  static final _idPattern = RegExp(r'^[a-z0-9][a-z0-9._-]{0,63}$');

  static const knownPlatforms = {'android', 'ios', 'web'};

  factory Announcement.fromJson(Map<String, dynamic> json) {
    final id = json['id'];
    if (id is! String || !_idPattern.hasMatch(id)) {
      throw const AnnouncementFormatException(
        '"id" must be 1–64 lowercase letters, digits, ".", "_" or "-"',
      );
    }
    final category = AnnouncementCategory.parse(json['category']);
    if (category == null) {
      throw AnnouncementFormatException(
        '"category" must be one of '
        '${AnnouncementCategory.values.map((c) => c.name).join(', ')}',
      );
    }
    final audience = AnnouncementAudience.parse(json['audience']);
    if (audience == null) {
      throw AnnouncementFormatException(
        '"audience" must be one of '
        '${AnnouncementAudience.values.map((a) => a.name).join(', ')}',
      );
    }
    final startsAt = _date(json['startsAt'], 'startsAt');
    final endsAt = _date(json['endsAt'], 'endsAt');
    if (startsAt != null && endsAt != null && !endsAt.isAfter(startsAt)) {
      throw const AnnouncementFormatException(
        '"endsAt" must be after "startsAt"',
      );
    }
    final minBuild = json['minBuild'] ?? 0;
    final maxBuild = json['maxBuild'];
    if (minBuild is! int || minBuild < 0) {
      throw const AnnouncementFormatException('"minBuild" must be an int ≥ 0');
    }
    if (maxBuild != null && (maxBuild is! int || maxBuild < minBuild)) {
      throw const AnnouncementFormatException(
        '"maxBuild" must be an int no lower than "minBuild"',
      );
    }
    final rawPlatforms = json['platforms'];
    final platforms = <String>{};
    if (rawPlatforms != null) {
      if (rawPlatforms is! List ||
          rawPlatforms.any((p) => !knownPlatforms.contains(p))) {
        throw AnnouncementFormatException(
          '"platforms" must list some of ${knownPlatforms.join(', ')}',
        );
      }
      platforms.addAll(rawPlatforms.cast<String>());
    }
    final priority = json['priority'] ?? 0;
    if (priority is! int) {
      throw const AnnouncementFormatException('"priority" must be an int');
    }
    return Announcement(
      id: id,
      category: category,
      title: LocalizedText.parse(json['title'], 'title'),
      body: LocalizedText.parse(json['body'], 'body'),
      highlight: LocalizedText.parse(
        json['highlight'],
        'highlight',
        required: false,
      ),
      action: AnnouncementAction.parse(json['action']),
      audience: audience,
      startsAt: startsAt,
      endsAt: endsAt,
      minBuild: minBuild,
      maxBuild: maxBuild as int?,
      platforms: platforms,
      priority: priority,
    );
  }

  static DateTime? _date(Object? raw, String field) {
    if (raw == null) return null;
    // A zone is required: "midnight" means a different moment in Tehran and
    // in UTC, and guessing wrong starts an offer hours early or late.
    final parsed = raw is String && RegExp(r'(Z|[+-]\d\d:?\d\d)$').hasMatch(raw)
        ? DateTime.tryParse(raw)
        : null;
    if (parsed == null) {
      throw AnnouncementFormatException(
        '"$field" must be an ISO 8601 time with a zone, like '
        '2026-11-05T00:00:00Z or 2026-11-05T00:00:00+03:30',
      );
    }
    return parsed.toUtc();
  }
}

/// The whole feed: the announcements that parsed, and why the rest did not.
class AnnouncementFeed {
  const AnnouncementFeed({
    required this.announcements,
    this.rejected = const [],
  });

  final List<Announcement> announcements;

  /// One line per dropped entry, for the log and the feed's own test.
  final List<String> rejected;

  factory AnnouncementFeed.fromJson(Map<String, dynamic> json) {
    final list = json['announcements'];
    if (list is! List) {
      throw const AnnouncementFormatException('no "announcements" list');
    }
    final good = <Announcement>[];
    final rejected = <String>[];
    final ids = <String>{};
    for (var i = 0; i < list.length; i++) {
      final raw = list[i];
      final label = raw is Map && raw['id'] is String
          ? '"${raw['id']}"'
          : '#$i';
      try {
        if (raw is! Map<String, dynamic>) {
          throw const AnnouncementFormatException('not an object');
        }
        final a = Announcement.fromJson(raw);
        if (!ids.add(a.id)) {
          throw const AnnouncementFormatException('the same id twice');
        }
        good.add(a);
      } on AnnouncementFormatException catch (e) {
        rejected.add('$label: ${e.message}');
      }
    }
    return AnnouncementFeed(announcements: good, rejected: rejected);
  }
}

class AnnouncementFormatException implements Exception {
  const AnnouncementFormatException(this.message);
  final String message;

  @override
  String toString() => 'AnnouncementFormatException: $message';
}

/// What this phone is, for deciding which announcements reach it.
class AnnouncementContext {
  const AnnouncementContext({
    required this.now,
    required this.build,
    required this.platform,
    required this.seen,
    this.signedIn = false,
    this.canSignIn = false,
    this.monetized = false,
    this.premium = false,
  });

  final DateTime now;
  final int build;

  /// android, ios or web.
  final String platform;

  /// Ids already shown on this phone.
  final Set<String> seen;
  final bool signedIn;

  /// Whether this build can sign in at all (accounts switched on).
  final bool canSignIn;

  /// Whether this build sells a subscription.
  final bool monetized;
  final bool premium;
}

/// The most announcements one sheet holds. More than this and people stop
/// reading; the rest wait for the next launch.
const maxAnnouncementsPerSheet = 3;

/// Which of [feed]'s announcements to show now, best first.
///
/// An announcement is left out when it was seen, is outside its dates or
/// builds or platforms, is for someone else — or asks for something this
/// build cannot do (a sign-up offer on a build without accounts would be a
/// button to nowhere).
List<Announcement> pickAnnouncements(
  AnnouncementFeed feed,
  AnnouncementContext ctx, {
  int limit = maxAnnouncementsPerSheet,
}) {
  bool reaches(Announcement a) {
    if (ctx.seen.contains(a.id)) return false;
    if (a.startsAt != null && ctx.now.isBefore(a.startsAt!)) return false;
    if (a.endsAt != null && !ctx.now.isBefore(a.endsAt!)) return false;
    if (ctx.build < a.minBuild) return false;
    if (a.maxBuild != null && ctx.build > a.maxBuild!) return false;
    if (a.platforms.isEmpty
        ? ctx.platform == 'web'
        : !a.platforms.contains(ctx.platform)) {
      return false;
    }
    final inAudience = switch (a.audience) {
      AnnouncementAudience.everyone => true,
      AnnouncementAudience.signedOut => ctx.canSignIn && !ctx.signedIn,
      AnnouncementAudience.signedIn => ctx.signedIn,
      AnnouncementAudience.free => ctx.monetized && !ctx.premium,
      AnnouncementAudience.premium => ctx.monetized && ctx.premium,
    };
    if (!inAudience) return false;
    final action = a.action;
    if (action?.type == AnnouncementActionType.signIn &&
        (!ctx.canSignIn || ctx.signedIn)) {
      return false;
    }
    return true;
  }

  final order = {
    for (var i = 0; i < feed.announcements.length; i++)
      feed.announcements[i].id: i,
  };
  final epoch = DateTime.fromMillisecondsSinceEpoch(0, isUtc: true);
  final picked = feed.announcements.where(reaches).toList()
    ..sort((a, b) {
      final byPriority = b.priority.compareTo(a.priority);
      if (byPriority != 0) return byPriority;
      final byStart = (b.startsAt ?? epoch).compareTo(a.startsAt ?? epoch);
      if (byStart != 0) return byStart;
      // List.sort is not stable; the file's own order settles the rest.
      return order[a.id]!.compareTo(order[b.id]!);
    });
  return picked.take(limit).toList();
}
