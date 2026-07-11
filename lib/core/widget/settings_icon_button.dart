import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../l10n/extension.dart';
import '../theme/app_colors.dart';

/// Settings entry point shared by the landing page and walkie header:
/// an amber-tinted chip matching the app's accent idiom (brand badge,
/// settings category cards), padded out to a 48dp touch target.
class SettingsIconButton extends StatelessWidget {
  const SettingsIconButton({super.key, required this.onTap});

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      label: context.getString.settings_gear_tooltip,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () {
          HapticFeedback.selectionClick();
          onTap();
        },
        child: Padding(
          padding: const EdgeInsets.all(4),
          child: Container(
            width: 40,
            height: 40,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: AppColors.amber.withAlpha(24),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: AppColors.amber.withAlpha(70)),
            ),
            child: Icon(
              Icons.settings_rounded,
              color: AppColors.amber,
              size: 20,
            ),
          ),
        ),
      ),
    );
  }
}
