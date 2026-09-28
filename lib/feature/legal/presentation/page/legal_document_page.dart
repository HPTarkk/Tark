import 'package:flutter/material.dart';

import '../../../../core/l10n/extension.dart';
import '../../../../core/motion/app_motion.dart';
import '../../../../core/theme/app_colors.dart';
import '../../domain/entity/legal_document.dart';
import '../widget/legal_document_view.dart';

/// One published document, in full.
///
/// Pushed from the consent gate, and usable on its own from Settings later.
/// Deliberately a plain reading surface — no motion, no reveal choreography:
/// this is the screen somebody opens because they actually want to read it,
/// and anything that animates while they do is in the way.
class LegalDocumentPage extends StatelessWidget {
  const LegalDocumentPage({required this.document, super.key});

  final LegalDocument document;

  @override
  Widget build(BuildContext context) {
    final language = Localizations.localeOf(context).languageCode;
    final strings = context.getString;

    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        backgroundColor: AppColors.background,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        title: Text(
          document.name(language),
          style: TextStyle(
            color: AppColors.textPrimary,
            fontSize: 16,
            fontWeight: FontWeight.w700,
          ),
        ),
      ),
      body: SafeArea(
        top: false,
        child: CustomScrollView(
          slivers: [
            SliverPadding(
              padding: const EdgeInsets.fromLTRB(20, 8, 20, 0),
              // The heading block arrives in the same stagger as every other
              // page; the long body below it simply scrolls.
              sliver: SliverToBoxAdapter(
                child: StaggeredEntrance(
                  builder: (context, items) => Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: items,
                  ),
                  children: [
                    Text(
                      document.heading(language),
                      style: TextStyle(
                        color: AppColors.textPrimary,
                        fontSize: 24,
                        height: 1.25,
                        fontWeight: FontWeight.w900,
                      ),
                    ),
                    Padding(
                      padding: const EdgeInsets.only(top: 12),
                      child: Text(
                        document.lede(language),
                        style: TextStyle(
                          color: AppColors.textSecondary,
                          fontSize: 14,
                          height: 1.7,
                        ),
                      ),
                    ),
                    Padding(
                      padding: const EdgeInsets.only(top: 16),
                      child: _EffectiveStamp(
                        label: strings.consent_effective_since,
                        date: document.effectiveDateLabel(language),
                      ),
                    ),
                    if (document.hasUnrenderableContent)
                      Padding(
                        padding: const EdgeInsets.only(top: 16),
                        child: _PartialNotice(strings.consent_partial_notice),
                      ),
                    Padding(
                      padding: const EdgeInsets.only(top: 22),
                      child: LegalSummaryView(
                        columns: document.summary,
                        language: language,
                      ),
                    ),
                  ],
                ),
              ),
            ),
            SliverPadding(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 40),
              sliver: LegalDocumentSlivers(
                document: document,
                language: language,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// The effective date, stamped rather than typeset — it is the line a
/// returning reader checks first.
class _EffectiveStamp extends StatelessWidget {
  const _EffectiveStamp({required this.label, required this.date});

  final String label;
  final String date;

  @override
  Widget build(BuildContext context) {
    return Align(
      alignment: AlignmentDirectional.centerStart,
      child: Container(
        decoration: BoxDecoration(
          color: AppColors.card,
          borderRadius: BorderRadius.circular(999),
          border: Border.all(color: AppColors.border),
        ),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 6,
              height: 6,
              decoration: BoxDecoration(
                color: AppColors.green,
                shape: BoxShape.circle,
              ),
            ),
            const SizedBox(width: 9),
            Text(
              label,
              style: TextStyle(
                color: AppColors.textSecondary,
                fontSize: 11.5,
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(width: 7),
            Text(
              date,
              style: TextStyle(
                color: AppColors.textPrimary,
                fontSize: 11.5,
                fontWeight: FontWeight.w800,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Shown when the document contains a block this build cannot render.
///
/// An app that quietly drops a paragraph out of a privacy policy is worse
/// than one that admits it and points at the full text.
class _PartialNotice extends StatelessWidget {
  const _PartialNotice(this.message);

  final String message;

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppColors.red.withValues(alpha: 0.45)),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      child: Text(
        message,
        style: TextStyle(
          color: AppColors.textSecondary,
          fontSize: 12.5,
          height: 1.6,
        ),
      ),
    );
  }
}
