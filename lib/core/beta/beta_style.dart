import 'package:flutter/material.dart';

import '../theme/theme_service.dart';

/// The Beta visual identity: a cool "lab glass" gradient, teal into violet.
///
/// Chosen to sit opposite everything else that already means something here.
/// Amber is the brand and the live path; gold/amber crowns are premium; green
/// is "connected", red is "trouble". Beta must not read as any of those — not
/// as a warning (it is not one), not as an upsell (it is free), not as the
/// main road. A cool gradient is the one temperature the palette leaves
/// unused, so the mark is recognisable at a glance without ever competing
/// with the amber call to action beside it.
///
/// Like `AppColors`, these are getters resolved against the active theme: the
/// light palette deepens both stops so the mark keeps contrast on cream.
abstract final class BetaStyle {
  static bool get _light => ThemeService.isLight;

  /// The leading stop — "fresh", the colour of something just made.
  static Color get teal =>
      _light ? const Color(0xFF0B8A7A) : const Color(0xFF5EEAD4);

  /// The trailing stop — "lab", the colour of something still being made.
  static Color get violet =>
      _light ? const Color(0xFF6A4ED6) : const Color(0xFFA78BFA);

  /// Text and glyphs drawn *on* a beta tint — the midpoint, nudged towards
  /// whichever stop reads better on the surface.
  static Color get ink => Color.lerp(teal, violet, 0.45)!;

  /// The sheen highlight swept across a badge. A hair of mint in the dark
  /// theme so the sweep reads as glass rather than glare; plain white on cream.
  static Color get sheen =>
      _light ? const Color(0xFFFFFFFF) : const Color(0xFFF2FFFC);

  static LinearGradient gradient({double alpha = 1}) => LinearGradient(
    begin: Alignment.centerLeft,
    end: Alignment.centerRight,
    colors: [
      teal.withValues(alpha: alpha),
      violet.withValues(alpha: alpha),
    ],
  );

  /// The tint a beta surface is washed with — enough to read as "a different
  /// kind of thing" next to a plain card, not enough to look like a button.
  static LinearGradient wash({double alpha = 0.14}) => gradient(alpha: alpha);

  /// One full shimmer cycle: the sweep takes the first [sheenShare] of it and
  /// the rest is rest. Slow on purpose — the badge is alive, not alarmed.
  static const Duration cycle = Duration(milliseconds: 4200);
  static const double sheenShare = 0.28;
}
