import 'package:flutter/material.dart';

import '../theme/app_colors.dart';

/// The app's bottom-sheet chrome: a floating rounded panel with an amber
/// hairline, a grabber, and a scrolling body.
///
/// Extracted from the People sheet once a second and third sheet wanted the
/// same frame. Three hand-rolled copies of a panel is how sheets start
/// drifting apart — one with a different radius, one with a different scrim —
/// and the drift is only ever visible when two of them are opened in a row.
class SheetShell extends StatelessWidget {
  const SheetShell({required this.child, this.topFraction = 0.08, super.key});

  final Widget child;

  /// How much of the screen stays uncovered above the sheet. A sheet that
  /// reaches the status bar has stopped being a sheet and become a page that
  /// lies about how to dismiss it.
  final double topFraction;

  @override
  Widget build(BuildContext context) => SafeArea(
    child: Padding(
      padding: EdgeInsets.only(
        left: 12,
        right: 12,
        bottom: 12,
        top: MediaQuery.sizeOf(context).height * topFraction,
      ),
      child: Container(
        decoration: BoxDecoration(
          color: AppColors.surface,
          borderRadius: BorderRadius.circular(24),
          border: Border.all(color: AppColors.amber.withValues(alpha: 0.22)),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.45),
              blurRadius: 40,
              offset: const Offset(0, 12),
            ),
          ],
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SheetGrabber(),
            Flexible(child: SingleChildScrollView(child: child)),
          ],
        ),
      ),
    ),
  );
}

class SheetGrabber extends StatelessWidget {
  const SheetGrabber({super.key});

  @override
  Widget build(BuildContext context) => Container(
    width: 38,
    height: 4,
    margin: const EdgeInsets.only(top: 10, bottom: 4),
    decoration: BoxDecoration(
      color: AppColors.textSecondary.withValues(alpha: 0.35),
      borderRadius: BorderRadius.circular(2),
    ),
  );
}

/// A small tracked eyebrow over a large title — the app's sheet heading.
class SheetTitle extends StatelessWidget {
  const SheetTitle({
    required this.title,
    required this.subtitle,
    this.accent,
    super.key,
  });

  /// The eyebrow. Uppercase and tracked; keep it to a word or two.
  final String title;
  final String subtitle;

  /// Overrides the eyebrow tint, for a sheet that is not about the live
  /// amber path — the archive, say.
  final Color? accent;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Text(
        title,
        style: TextStyle(
          color: accent ?? AppColors.amber,
          fontSize: 11,
          fontWeight: FontWeight.w800,
          letterSpacing: 2,
        ),
      ),
      const SizedBox(height: 4),
      Text(
        subtitle,
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(
          color: AppColors.textPrimary,
          fontSize: 21,
          fontWeight: FontWeight.w800,
        ),
      ),
    ],
  );
}
