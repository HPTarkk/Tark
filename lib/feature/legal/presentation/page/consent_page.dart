import 'package:flutter/material.dart';

import '../../../../core/l10n/extension.dart';
import '../../../../core/theme/app_colors.dart';
import '../../../../core/widget/tark_mark.dart';
import '../manager/consent_state.dart';
import '../widget/legal_document_view.dart';
import 'legal_document_page.dart';

/// The gate: what somebody sees when there is a published document they have
/// not agreed to.
///
/// ## What this screen is trying not to be
///
/// A wall of legal text with a button under it is the pattern everybody has
/// learned to scroll past without reading, and this app's whole tone is an
/// argument against that. So the *short version* of each document — the same
/// two-column ledger the website leads with — is what is actually on screen,
/// and the full text is one tap away rather than 4,000 words deep.
///
/// It is still a gate. There is no dismiss, no back, and no way past it but
/// the button, because that is what was asked for. What it does not do is
/// pretend the reader has read something they have not.
class ConsentPage extends StatelessWidget {
  const ConsentPage({
    required this.pending,
    required this.isSaving,
    required this.onAccept,
    super.key,
  });

  final List<PendingConsent> pending;
  final bool isSaving;
  final VoidCallback onAccept;

  bool get _isFirstRun => pending.every((p) => p.isFirstTime);

  @override
  Widget build(BuildContext context) {
    final strings = context.getString;
    final language = Localizations.localeOf(context).languageCode;

    // No Navigator to pop to and no system back: this is a gate, and a
    // gesture must not be a way around it.
    return PopScope(
      canPop: false,
      child: Scaffold(
        backgroundColor: AppColors.background,
        body: SafeArea(
          child: Column(
            children: [
              Expanded(
                child: ListView(
                  padding: const EdgeInsets.fromLTRB(22, 28, 22, 20),
                  children: [
                    TarkMark(size: 34, color: AppColors.amber),
                    const SizedBox(height: 26),
                    Text(
                      _isFirstRun
                          ? strings.consent_title_first
                          : strings.consent_title_updated,
                      style: TextStyle(
                        color: AppColors.textPrimary,
                        fontSize: 27,
                        height: 1.2,
                        fontWeight: FontWeight.w900,
                      ),
                    ),
                    const SizedBox(height: 12),
                    Text(
                      _isFirstRun
                          ? strings.consent_body_first
                          : strings.consent_body_updated,
                      style: TextStyle(
                        color: AppColors.textSecondary,
                        fontSize: 14,
                        height: 1.7,
                      ),
                    ),
                    const SizedBox(height: 26),
                    for (final item in pending)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 16),
                        child: _DocumentCard(item: item, language: language),
                      ),
                  ],
                ),
              ),
              _AcceptBar(
                label: strings.consent_accept,
                isSaving: isSaving,
                onAccept: onAccept,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _DocumentCard extends StatelessWidget {
  const _DocumentCard({required this.item, required this.language});

  final PendingConsent item;
  final String language;

  @override
  Widget build(BuildContext context) {
    final strings = context.getString;
    final document = item.document;

    return DecoratedBox(
      decoration: BoxDecoration(
        color: AppColors.card,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: AppColors.border),
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(18, 18, 18, 10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    document.name(language),
                    style: TextStyle(
                      color: AppColors.textPrimary,
                      fontSize: 17,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                ),
                _Badge(
                  // "New" and "Updated" are different facts and a reader
                  // deserves to know which one they are looking at.
                  label: item.isFirstTime
                      ? strings.consent_new_badge
                      : strings.consent_updated_badge,
                  language: language,
                ),
              ],
            ),
            const SizedBox(height: 6),
            Text(
              '${strings.consent_effective_since} '
              '${document.effectiveDateLabel(language)}',
              style: TextStyle(
                color: AppColors.textSecondary,
                fontSize: 12,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 18),
            Text(
              strings.consent_short_version,
              style: TextStyle(
                color: AppColors.textSecondary,
                fontSize: 10.5,
                fontWeight: FontWeight.w800,
                letterSpacing: language == 'fa' ? 0 : 1.6,
              ),
            ),
            const SizedBox(height: 12),
            LegalSummaryView(columns: document.summary, language: language),
            Align(
              alignment: AlignmentDirectional.centerStart,
              child: TextButton(
                onPressed: () => Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    builder: (_) => LegalDocumentPage(document: document),
                  ),
                ),
                style: TextButton.styleFrom(
                  foregroundColor: AppColors.amber,
                  padding: const EdgeInsets.symmetric(vertical: 6),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      strings.consent_read_full,
                      style: const TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                    const SizedBox(width: 6),
                    const Icon(Icons.arrow_forward, size: 15),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _Badge extends StatelessWidget {
  const _Badge({required this.label, required this.language});

  final String label;
  final String language;

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: AppColors.amber.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: AppColors.amber.withValues(alpha: 0.4)),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      child: Text(
        label,
        style: TextStyle(
          color: AppColors.amber,
          fontSize: 9.5,
          fontWeight: FontWeight.w800,
          letterSpacing: language == 'fa' ? 0 : 1.2,
        ),
      ),
    );
  }
}

/// The one way past this screen.
class _AcceptBar extends StatelessWidget {
  const _AcceptBar({
    required this.label,
    required this.isSaving,
    required this.onAccept,
  });

  final String label;
  final bool isSaving;
  final VoidCallback onAccept;

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: AppColors.background,
        border: BorderDirectional(top: BorderSide(color: AppColors.border)),
      ),
      padding: const EdgeInsets.fromLTRB(22, 14, 22, 18),
      child: SizedBox(
        width: double.infinity,
        height: 52,
        child: FilledButton(
          // Disabled while writing, so a double tap cannot record twice or
          // race the re-check that follows it.
          onPressed: isSaving ? null : onAccept,
          style: FilledButton.styleFrom(
            backgroundColor: AppColors.amber,
            foregroundColor: Colors.black,
            disabledBackgroundColor: AppColors.amber.withValues(alpha: 0.5),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(14),
            ),
          ),
          child: isSaving
              ? const SizedBox(
                  width: 20,
                  height: 20,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    color: Colors.black,
                  ),
                )
              : Text(
                  label,
                  style: const TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w800,
                  ),
                ),
        ),
      ),
    );
  }
}
