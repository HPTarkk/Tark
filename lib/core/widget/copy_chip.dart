import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../motion/app_motion.dart';
import '../theme/app_colors.dart';

/// Small tap-to-copy chip whose own label answers the tap.
///
/// Copying used to raise a `SnackBar` from some screens and swap the button in
/// place on others. It now always swaps in place (the same [TapConfirmation]
/// the Room invite sheet uses): the icon turns into a green check and [label]
/// into [copiedLabel] for a beat, right where the user is looking.
class CopyChip extends StatelessWidget {
  const CopyChip({
    required this.text,
    required this.label,
    required this.copiedLabel,
    super.key,
  });

  /// What lands on the clipboard.
  final String text;
  final String label;
  final String copiedLabel;

  @override
  Widget build(BuildContext context) => TapConfirmation(
    builder: (context, copied, confirm) {
      final color = copied ? AppColors.green : AppColors.amber;
      return Semantics(
        button: true,
        liveRegion: copied,
        child: PressableScale(
          onTap: () async {
            await Clipboard.setData(ClipboardData(text: text));
            confirm();
          },
          child: AnimatedContainer(
            duration: AppMotion.chip,
            curve: AppMotion.easeOut,
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
            decoration: BoxDecoration(
              color: AppColors.card,
              borderRadius: BorderRadius.circular(10),
              border: Border.all(
                color: copied
                    ? AppColors.green.withValues(alpha: 0.6)
                    : AppColors.border,
              ),
            ),
            child: AnimatedSwitcher(
              duration: AppMotion.chip,
              switchInCurve: AppMotion.easeOut,
              switchOutCurve: AppMotion.leaving,
              child: Row(
                key: ValueKey<bool>(copied),
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    copied ? Icons.check_rounded : Icons.copy_rounded,
                    color: color,
                    size: 14,
                  ),
                  const SizedBox(width: 6),
                  Text(
                    copied ? copiedLabel : label,
                    style: TextStyle(
                      color: color,
                      fontSize: 11,
                      fontWeight: FontWeight.w700,
                      letterSpacing: 1,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      );
    },
  );
}

/// Icon-only copy button: the copy glyph turns into a green check for a beat.
///
/// For rows too narrow for a [CopyChip], such as a hotspot's name and
/// password. [copiedLabel] is announced to screen readers when it flips.
class CopyIconButton extends StatelessWidget {
  const CopyIconButton({
    required this.text,
    required this.copiedLabel,
    super.key,
  });

  final String text;
  final String copiedLabel;

  @override
  Widget build(BuildContext context) => TapConfirmation(
    builder: (context, copied, confirm) => Semantics(
      button: true,
      liveRegion: copied,
      label: copied ? copiedLabel : null,
      child: PressableScale(
        onTap: () async {
          await Clipboard.setData(ClipboardData(text: text));
          confirm();
        },
        child: Padding(
          padding: const EdgeInsetsDirectional.only(start: 8),
          child: AnimatedSwitcher(
            duration: AppMotion.chip,
            switchInCurve: AppMotion.easeOut,
            switchOutCurve: AppMotion.leaving,
            child: Icon(
              copied ? Icons.check_rounded : Icons.copy_rounded,
              key: ValueKey<bool>(copied),
              color: copied ? AppColors.green : AppColors.amber,
              size: 18,
            ),
          ),
        ),
      ),
    ),
  );
}
