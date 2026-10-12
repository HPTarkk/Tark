import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../../core/l10n/extension.dart';
import '../../../../core/motion/app_motion.dart';
import '../../../../core/theme/app_colors.dart';

/// "Can they invite people too?" — one tap, right under the invite code.
///
/// The choice belongs to whoever is showing the code, and it is made *on* the
/// code: flipping it re-signs the certificate inside the QR, so what is on
/// screen is always exactly what will be granted. There is no hidden setting
/// to remember and no second screen.
///
/// The row says what will happen in both states rather than naming a
/// permission, because "permission" is the technical word and "they can bring
/// their friends" is the decision a rider is actually making.
///
/// Motion: the glyph swaps with a short overshoot (a person gaining a "+"),
/// the hint slides in from the side the switch travelled, and the frame warms
/// to amber. Under reduced motion only the colour and the fade remain.
class RoomInviteGrantToggle extends StatelessWidget {
  const RoomInviteGrantToggle({
    super.key,
    required this.value,
    required this.onChanged,
    this.enabled = true,
  });

  final bool value;
  final ValueChanged<bool> onChanged;

  /// False while the code is being re-signed, so a second tap cannot race the
  /// first one's certificate.
  final bool enabled;

  void _flip() {
    if (!enabled) return;
    HapticFeedback.selectionClick();
    onChanged(!value);
  }

  @override
  Widget build(BuildContext context) {
    final s = context.getString;
    final reduced = AppMotion.reduced(context);
    final accent = value ? AppColors.amber : AppColors.textSecondary;
    final hint = value ? s.invitegrant_on_hint : s.invitegrant_off_hint;
    return Semantics(
      toggled: value,
      enabled: enabled,
      label: s.people_grant_title,
      hint: hint,
      excludeSemantics: true,
      onTap: enabled ? _flip : null,
      child: PressableScale(
        onTap: enabled ? _flip : null,
        borderRadius: BorderRadius.circular(14),
        child: AnimatedContainer(
          key: const Key('room-invite-grant-toggle'),
          duration: AppMotion.card,
          curve: AppMotion.easeOut,
          padding: const EdgeInsets.fromLTRB(12, 9, 6, 9),
          decoration: BoxDecoration(
            color: value
                ? AppColors.amber.withValues(alpha: 0.10)
                : AppColors.card,
            borderRadius: BorderRadius.circular(14),
            border: Border.all(
              color: value
                  ? AppColors.amber.withValues(alpha: 0.55)
                  : AppColors.border,
            ),
          ),
          child: Row(
            children: [
              AnimatedContainer(
                duration: AppMotion.card,
                curve: AppMotion.easeOut,
                width: 34,
                height: 34,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: accent.withValues(alpha: 0.14),
                ),
                alignment: Alignment.center,
                child: AnimatedSwitcher(
                  duration: reduced ? AppMotion.chip : AppMotion.sheet,
                  switchInCurve: reduced ? Curves.linear : Curves.easeOutBack,
                  switchOutCurve: AppMotion.leaving,
                  transitionBuilder: (child, animation) => FadeTransition(
                    opacity: animation,
                    child: reduced
                        ? child
                        : ScaleTransition(
                            scale: Tween<double>(
                              begin: 0.55,
                              end: 1,
                            ).animate(animation),
                            child: child,
                          ),
                  ),
                  child: Icon(
                    value
                        ? Icons.group_add_rounded
                        : Icons.person_outline_rounded,
                    key: ValueKey(value),
                    size: 18,
                    color: accent,
                  ),
                ),
              ),
              const SizedBox(width: 11),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    AnimatedDefaultTextStyle(
                      duration: AppMotion.card,
                      curve: AppMotion.easeOut,
                      // Merged, not replaced: this widget swaps the whole
                      // inherited style, and on its own would drop the app
                      // font for the platform's.
                      style: DefaultTextStyle.of(context).style.merge(
                        TextStyle(
                          color: value
                              ? AppColors.amber
                              : AppColors.textPrimary,
                          fontSize: 13,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      child: Text(s.people_grant_title),
                    ),
                    const SizedBox(height: 2),
                    AnimatedSwitcher(
                      duration: AppMotion.card,
                      switchInCurve: AppMotion.easeOut,
                      switchOutCurve: AppMotion.leaving,
                      layoutBuilder: (current, previous) => Stack(
                        alignment: AlignmentDirectional.centerStart,
                        children: [...previous, ?current],
                      ),
                      transitionBuilder: (child, animation) {
                        final fade = FadeTransition(
                          opacity: animation,
                          child: child,
                        );
                        if (reduced) return fade;
                        // Travels with the switch thumb: in from the end when
                        // turning on, from the start when turning off.
                        final from = value ? 0.12 : -0.12;
                        final dir = Directionality.of(context);
                        final dx = dir == TextDirection.rtl ? -from : from;
                        return SlideTransition(
                          position: Tween<Offset>(
                            begin: Offset(dx, 0),
                            end: Offset.zero,
                          ).animate(animation),
                          child: fade,
                        );
                      },
                      child: Text(
                        hint,
                        key: ValueKey(value),
                        style: TextStyle(
                          color: AppColors.textSecondary,
                          fontSize: 11,
                          height: 1.4,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              ExcludeSemantics(
                child: Switch(
                  value: value,
                  onChanged: enabled ? (_) => _flip() : null,
                  activeThumbColor: AppColors.amber,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
