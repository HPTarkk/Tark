import 'package:flutter/material.dart';

import '../../../../core/theme/app_colors.dart';
import '../../domain/entity/legal_document.dart';

/// Renders a published legal document with the same block vocabulary the
/// website uses — paragraphs, sub-headings, bullets, callouts and labelled
/// rows — so the app and tarkk.ir show the same document rather than two
/// summaries of it.
///
/// Slivers rather than a Column in a ScrollView: the privacy policy is a few
/// hundred paragraphs' worth of text on a phone, and building all of it for
/// every frame of a scroll is exactly the sort of thing that costs frames on
/// the low-end hardware this app is held to.
class LegalDocumentSlivers extends StatelessWidget {
  const LegalDocumentSlivers({
    required this.document,
    required this.language,
    super.key,
  });

  final LegalDocument document;

  /// `en` or `fa`. Passed in rather than read from context so a test can
  /// render either without a full localisation harness.
  final String language;

  @override
  Widget build(BuildContext context) {
    final children = <Widget>[];

    for (final (index, section) in document.sections.indexed) {
      children.add(
        _SectionHeading(number: index + 1, title: section.title(language)),
      );
      for (final block in section.blocks) {
        children.add(_Block(block: block, language: language));
      }
      if (index != document.sections.length - 1) {
        children.add(const _Rule());
      }
    }

    return SliverList(delegate: SliverChildListDelegate.fixed(children));
  }
}

/// The two-column "short version" that opens each document, laid out as one
/// column on a phone.
///
/// Worth showing above the full text rather than below it: it is the part a
/// reader being asked to accept something will actually read.
class LegalSummaryView extends StatelessWidget {
  const LegalSummaryView({
    required this.columns,
    required this.language,
    super.key,
  });

  final List<LegalSummaryColumn> columns;
  final String language;

  @override
  Widget build(BuildContext context) {
    if (columns.isEmpty) return const SizedBox.shrink();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final column in columns)
          Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: AppColors.surface,
                borderRadius: BorderRadius.circular(16),
                border: Border.all(color: AppColors.border),
              ),
              child: Padding(
                padding: const EdgeInsets.fromLTRB(18, 18, 18, 20),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      column.title(language),
                      style: TextStyle(
                        color: AppColors.textSecondary,
                        fontSize: 11,
                        fontWeight: FontWeight.w800,
                        letterSpacing: language == 'fa' ? 0 : 1.6,
                      ),
                    ),
                    const SizedBox(height: 14),
                    for (final item in column.items)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 10),
                        child: _Bullet(
                          // The website marks these columns with a + and a −;
                          // the same distinction, in the same colours.
                          glyph: column.positive ? '+' : '−',
                          color: column.positive
                              ? AppColors.amber
                              : AppColors.green,
                          text: item(language),
                        ),
                      ),
                  ],
                ),
              ),
            ),
          ),
      ],
    );
  }
}

class _SectionHeading extends StatelessWidget {
  const _SectionHeading({required this.number, required this.title});

  final int number;
  final String title;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: 26, bottom: 12),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 26,
            height: 26,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: AppColors.surface,
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: AppColors.border),
            ),
            child: Text(
              // Localised digits, the same rule the rest of the app follows:
              // quantities get ۰-۹, identifiers stay Latin. A section number
              // is a quantity.
              _localizeDigits(context, '$number'),
              style: TextStyle(
                color: AppColors.amber,
                fontSize: 11,
                fontWeight: FontWeight.w800,
              ),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Padding(
              padding: const EdgeInsets.only(top: 2),
              child: Text(
                title,
                style: TextStyle(
                  color: AppColors.textPrimary,
                  fontSize: 17,
                  height: 1.3,
                  fontWeight: FontWeight.w800,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _Block extends StatelessWidget {
  const _Block({required this.block, required this.language});

  final LegalBlock block;
  final String language;

  @override
  Widget build(BuildContext context) {
    return switch (block) {
      LegalParagraph(:final text) => _Body(text(language)),
      LegalSubheading(:final text) => Padding(
        padding: const EdgeInsets.only(top: 18, bottom: 6),
        child: Text(
          text(language),
          style: TextStyle(
            color: AppColors.textPrimary,
            fontSize: 14,
            fontWeight: FontWeight.w800,
          ),
        ),
      ),
      LegalList(:final items) => Padding(
        padding: const EdgeInsets.only(top: 6, bottom: 4),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            for (final item in items)
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: _Bullet(
                  glyph: '•',
                  color: AppColors.amber,
                  text: item(language),
                ),
              ),
          ],
        ),
      ),
      LegalNote(:final label, :final text) => _Note(
        label: label(language),
        text: text(language),
        language: language,
      ),
      LegalRows(:final rows) => Padding(
        padding: const EdgeInsets.only(top: 10),
        child: Column(
          children: [
            for (final row in rows)
              _Row(
                name: row.name(language),
                text: row.text(language),
                isLink: row.href != null,
              ),
          ],
        ),
      ),
      // Deliberately nothing. The document said something this build cannot
      // render; the screen says so once, at the top, rather than leaving a
      // gap here that reads as the end of a sentence.
      LegalUnknownBlock() => const SizedBox.shrink(),
    };
  }
}

class _Body extends StatelessWidget {
  const _Body(this.text);
  final String text;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Text(
        text,
        style: TextStyle(
          color: AppColors.textSecondary,
          fontSize: 13.5,
          height: 1.75,
        ),
      ),
    );
  }
}

class _Bullet extends StatelessWidget {
  const _Bullet({
    required this.glyph,
    required this.color,
    required this.text,
  });

  final String glyph;
  final Color color;
  final String text;

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(top: 3),
          child: Text(
            glyph,
            style: TextStyle(
              color: color,
              fontSize: 13,
              fontWeight: FontWeight.w800,
            ),
          ),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: Text(
            text,
            style: TextStyle(
              color: AppColors.textSecondary,
              fontSize: 13,
              height: 1.65,
            ),
          ),
        ),
      ],
    );
  }
}

class _Note extends StatelessWidget {
  const _Note({
    required this.label,
    required this.text,
    required this.language,
  });

  final String label;
  final String text;
  final String language;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: 6, bottom: 14),
      child: Container(
        decoration: BoxDecoration(
          color: AppColors.surface,
          borderRadius: const BorderRadiusDirectional.horizontal(
            start: Radius.circular(4),
            end: Radius.circular(14),
          ),
          border: BorderDirectional(
            top: BorderSide(color: AppColors.border),
            end: BorderSide(color: AppColors.border),
            bottom: BorderSide(color: AppColors.border),
            start: BorderSide(color: AppColors.amber, width: 2),
          ),
        ),
        padding: const EdgeInsets.fromLTRB(16, 14, 16, 16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              label,
              style: TextStyle(
                color: AppColors.textPrimary,
                fontSize: 11,
                fontWeight: FontWeight.w800,
                letterSpacing: language == 'fa' ? 0 : 1.2,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              text,
              style: TextStyle(
                color: AppColors.textSecondary,
                fontSize: 13,
                height: 1.7,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _Row extends StatelessWidget {
  const _Row({required this.name, required this.text, required this.isLink});

  final String name;
  final String text;
  final bool isLink;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            name,
            style: TextStyle(
              // A row titled by a link is a third party's name; it is not
              // tappable here because this screen is a document, not a place
              // to be sent out of mid-consent.
              color: isLink ? AppColors.amber : AppColors.textPrimary,
              fontSize: 13,
              fontWeight: FontWeight.w800,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            text,
            style: TextStyle(
              color: AppColors.textSecondary,
              fontSize: 13,
              height: 1.65,
            ),
          ),
        ],
      ),
    );
  }
}

class _Rule extends StatelessWidget {
  const _Rule();

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: 14),
      child: Divider(height: 1, thickness: 1, color: AppColors.border),
    );
  }
}

/// Section numbers follow the app's digit rule — quantities localise, codes
/// do not. Kept private here rather than reaching for the shared extension,
/// which needs a BuildContext with AppLocalizations in scope.
String _localizeDigits(BuildContext context, String value) {
  if (Localizations.localeOf(context).languageCode != 'fa') return value;
  const fa = ['۰', '۱', '۲', '۳', '۴', '۵', '۶', '۷', '۸', '۹'];
  return value.replaceAllMapped(
    RegExp(r'\d'),
    (m) => fa[int.parse(m[0]!)],
  );
}
