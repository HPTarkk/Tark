import 'package:equatable/equatable.dart';

/// A string that exists in both of the app's languages.
///
/// The published documents store their text this way — one structure with an
/// `{en, fa}` pair at every leaf — rather than as two parallel trees. That is
/// what makes a half-translated policy impossible to ship: there is no shape
/// in which one language has a section the other does not.
///
/// It is also why the app can render either language from a single download,
/// which matters more here than it looks: somebody who switches the app to
/// English on a phone that has been offline for a month still gets a policy
/// they can read.
final class LocalizedText extends Equatable {
  const LocalizedText({required this.en, required this.fa});

  factory LocalizedText.fromJson(Object? json, String where) {
    if (json is String) {
      // A deliberately language-neutral value: a brand name, an email
      // address. Stored as a bare string in the document rather than as a
      // pair that repeats itself.
      return LocalizedText(en: json, fa: json);
    }
    if (json is! Map) {
      throw LegalFormatException('$where: expected a string or {en, fa}');
    }
    final en = json['en'];
    final fa = json['fa'];
    if (en is! String || fa is! String || en.isEmpty || fa.isEmpty) {
      throw LegalFormatException('$where: needs a non-empty "en" and "fa"');
    }
    return LocalizedText(en: en, fa: fa);
  }

  final String en;
  final String fa;

  /// Picks by language code. Anything that is not Persian gets English,
  /// which is the same rule the rest of the app applies.
  String call(String languageCode) => languageCode == 'fa' ? fa : en;

  @override
  List<Object?> get props => [en, fa];
}

/// The document was not shaped the way this build understands.
///
/// Thrown only inside parsing and turned into a failure at the repository
/// boundary — see `LegalRepository`. It exists so a malformed *downloaded*
/// document is rejected in one place rather than half-applied.
class LegalFormatException implements Exception {
  const LegalFormatException(this.message);
  final String message;

  @override
  String toString() => 'LegalFormatException: $message';
}

/// One piece of a section's body.
///
/// A closed set, matching what `scripts/build-legal-pages.mjs` renders on the
/// website. Keeping the two in step is what lets the app and the site show
/// the same document rather than two summaries of it.
sealed class LegalBlock extends Equatable {
  const LegalBlock();

  static LegalBlock fromJson(Map<String, dynamic> json, String where) {
    final type = json['type'];
    return switch (type) {
      'p' => LegalParagraph(
        LocalizedText.fromJson(json['text'], '$where.text'),
      ),
      'h3' => LegalSubheading(
        LocalizedText.fromJson(json['text'], '$where.text'),
      ),
      'list' => LegalList(
        _list(json['items'], '$where.items')
            .indexed
            .map((e) => LocalizedText.fromJson(e.$2, '$where.items[${e.$1}]'))
            .toList(growable: false),
      ),
      'note' => LegalNote(
        label: LocalizedText.fromJson(json['label'], '$where.label'),
        text: LocalizedText.fromJson(json['text'], '$where.text'),
      ),
      'rows' => LegalRows(
        _list(json['items'], '$where.items')
            .indexed
            .map((e) => LegalRow.fromJson(e.$2, '$where.items[${e.$1}]'))
            .toList(growable: false),
      ),
      // A newer document may carry a block this build has never heard of.
      // That is not a reason to reject the whole policy — it is a reason to
      // show the rest and say so. See LegalUnknownBlock.
      _ => LegalUnknownBlock(type is String ? type : '$type'),
    };
  }

  static List<Object?> _list(Object? value, String where) {
    if (value is! List || value.isEmpty) {
      throw LegalFormatException('$where: expected a non-empty list');
    }
    return value;
  }
}

final class LegalParagraph extends LegalBlock {
  const LegalParagraph(this.text);
  final LocalizedText text;

  @override
  List<Object?> get props => [text];
}

final class LegalSubheading extends LegalBlock {
  const LegalSubheading(this.text);
  final LocalizedText text;

  @override
  List<Object?> get props => [text];
}

final class LegalList extends LegalBlock {
  const LegalList(this.items);
  final List<LocalizedText> items;

  @override
  List<Object?> get props => [items];
}

/// A callout: the handful of statements a reader is worse off skimming past.
final class LegalNote extends LegalBlock {
  const LegalNote({required this.label, required this.text});
  final LocalizedText label;
  final LocalizedText text;

  @override
  List<Object?> get props => [label, text];
}

final class LegalRows extends LegalBlock {
  const LegalRows(this.rows);
  final List<LegalRow> rows;

  @override
  List<Object?> get props => [rows];
}

/// A block type added after this build shipped.
///
/// Rendered as nothing, but its presence is what lets the UI tell the reader
/// that the app is showing an incomplete rendering and point them at the web
/// version — which is a far better outcome than either crashing or quietly
/// dropping a paragraph out of a legal document.
final class LegalUnknownBlock extends LegalBlock {
  const LegalUnknownBlock(this.type);
  final String type;

  @override
  List<Object?> get props => [type];
}

/// One labelled row: a permission and what it is for, a service and what it
/// sees. The label is either translated text or a link whose name is the same
/// in both languages.
final class LegalRow extends Equatable {
  const LegalRow({required this.name, required this.text, this.href});

  factory LegalRow.fromJson(Object? json, String where) {
    if (json is! Map<String, dynamic>) {
      throw LegalFormatException('$where: expected an object');
    }
    final href = json['href'];
    return LegalRow(
      name: LocalizedText.fromJson(json['name'], '$where.name'),
      text: LocalizedText.fromJson(json['text'], '$where.text'),
      href: href is String && href.isNotEmpty ? href : null,
    );
  }

  final LocalizedText name;
  final LocalizedText text;

  /// Present when the row is titled by a link — a third party's own site, or
  /// a `mailto:`.
  final String? href;

  @override
  List<Object?> get props => [name, text, href];
}

/// A numbered section of a document.
final class LegalSection extends Equatable {
  const LegalSection({
    required this.id,
    required this.title,
    required this.blocks,
  });

  factory LegalSection.fromJson(Map<String, dynamic> json, String where) {
    final id = json['id'];
    if (id is! String || id.isEmpty) {
      throw LegalFormatException('$where: missing id');
    }
    final blocks = json['blocks'];
    if (blocks is! List || blocks.isEmpty) {
      throw LegalFormatException('$where($id): no blocks');
    }
    return LegalSection(
      id: id,
      title: LocalizedText.fromJson(json['title'], '$where($id).title'),
      blocks: blocks.indexed
          .map(
            (e) => LegalBlock.fromJson(
              e.$2 is Map<String, dynamic>
                  ? e.$2 as Map<String, dynamic>
                  : throw LegalFormatException(
                      '$where($id).blocks[${e.$1}]: expected an object',
                    ),
              '$where($id).blocks[${e.$1}]',
            ),
          )
          .toList(growable: false),
    );
  }

  final String id;
  final LocalizedText title;
  final List<LegalBlock> blocks;

  @override
  List<Object?> get props => [id, title, blocks];
}

/// The two-column "short version" that opens each document.
final class LegalSummaryColumn extends Equatable {
  const LegalSummaryColumn({
    required this.positive,
    required this.title,
    required this.items,
  });

  factory LegalSummaryColumn.fromJson(Map<String, dynamic> json, String where) {
    final items = json['items'];
    if (items is! List || items.isEmpty) {
      throw LegalFormatException('$where: no items');
    }
    return LegalSummaryColumn(
      // "asks" is the column of things that do happen, "nevers" the column of
      // things that do not — the website styles them with a + and a −.
      positive: json['kind'] != 'nevers',
      title: LocalizedText.fromJson(json['title'], '$where.title'),
      items: items.indexed
          .map((e) => LocalizedText.fromJson(e.$2, '$where.items[${e.$1}]'))
          .toList(growable: false),
    );
  }

  /// Whether these are things that happen (`true`) or things that never do.
  final bool positive;
  final LocalizedText title;
  final List<LocalizedText> items;

  @override
  List<Object?> get props => [positive, title, items];
}

/// A published legal document, in both languages, exactly as the website
/// renders it.
final class LegalDocument extends Equatable {
  const LegalDocument({
    required this.id,
    required this.name,
    required this.version,
    required this.minAcceptedVersion,
    required this.effectiveDate,
    required this.effectiveDateLabel,
    required this.webPath,
    required this.heading,
    required this.lede,
    required this.summary,
    required this.sections,
  });

  /// The schema this build knows how to read. A document declaring anything
  /// else is refused rather than guessed at.
  static const supportedSchema = 1;

  factory LegalDocument.fromJson(Map<String, dynamic> json) {
    final schema = json['schema'];
    if (schema != supportedSchema) {
      throw LegalFormatException(
        'unsupported schema $schema (this build reads $supportedSchema)',
      );
    }
    final id = json['id'];
    if (id is! String || id.isEmpty) {
      throw const LegalFormatException('document has no id');
    }

    final sections = json['sections'];
    if (sections is! List || sections.isEmpty) {
      throw LegalFormatException('$id: no sections');
    }

    final summary = json['summary'];
    final columns = summary is Map ? summary['columns'] : null;

    final hero = json['hero'];
    if (hero is! Map<String, dynamic>) {
      throw LegalFormatException('$id: no hero');
    }

    return LegalDocument(
      id: id,
      name: LocalizedText.fromJson(json['name'], '$id.name'),
      version: _version(json['version'], '$id.version'),
      minAcceptedVersion: _version(
        json['minAcceptedVersion'],
        '$id.minAcceptedVersion',
      ),
      effectiveDate: _date(json['effectiveDate'], '$id.effectiveDate'),
      effectiveDateLabel: LocalizedText.fromJson(
        json['effectiveDateLabel'],
        '$id.effectiveDateLabel',
      ),
      webPath: LocalizedText.fromJson(json['webPath'], '$id.webPath'),
      heading: LocalizedText.fromJson(hero['heading'], '$id.hero.heading'),
      lede: LocalizedText.fromJson(hero['lede'], '$id.hero.lede'),
      summary: columns is List
          ? columns.indexed
                .map(
                  (e) => LegalSummaryColumn.fromJson(
                    e.$2 as Map<String, dynamic>,
                    '$id.summary.columns[${e.$1}]',
                  ),
                )
                .toList(growable: false)
          : const <LegalSummaryColumn>[],
      sections: sections.indexed
          .map(
            (e) => LegalSection.fromJson(
              e.$2 as Map<String, dynamic>,
              '$id.sections[${e.$1}]',
            ),
          )
          .toList(growable: false),
    );
  }

  static int _version(Object? value, String where) {
    if (value is! int || value < 1) {
      throw LegalFormatException('$where: expected a positive integer');
    }
    return value;
  }

  static DateTime _date(Object? value, String where) {
    if (value is! String) throw LegalFormatException('$where: expected a date');
    final parsed = DateTime.tryParse(value);
    if (parsed == null) throw LegalFormatException('$where: unparseable "$value"');
    return parsed;
  }

  /// Which document this is: `privacy` or `terms`.
  final String id;

  /// Its short display name — "Privacy Policy", not the page's `<title>`.
  final LocalizedText name;

  /// Increments on every published change, typo fixes included.
  final int version;

  /// The oldest [version] still counted as accepted.
  ///
  /// This is the knob that decides whether anyone is asked again. A typo fix
  /// raises [version] and leaves this alone, so nobody is interrupted for a
  /// missing comma; a substantive change raises both.
  final int minAcceptedVersion;

  final DateTime effectiveDate;

  /// The date as the reader sees it — "8 September 2026", "۱۷ شهریور ۱۴۰۵".
  /// Localised in the document rather than formatted here, because the
  /// Persian copy uses the Solar Hijri calendar and its own digits.
  final LocalizedText effectiveDateLabel;

  /// Where to read this on the web, per language.
  final LocalizedText webPath;

  final LocalizedText heading;
  final LocalizedText lede;
  final List<LegalSummaryColumn> summary;
  final List<LegalSection> sections;

  /// True when the document contains anything this build cannot render, so
  /// the UI can say so instead of silently showing a shortened policy.
  bool get hasUnrenderableContent =>
      sections.any((s) => s.blocks.any((b) => b is LegalUnknownBlock));

  @override
  List<Object?> get props => [id, version, minAcceptedVersion, effectiveDate];
}
