import 'package:flutter/material.dart';

import '../motion/app_motion.dart';

/// A name reduced to its first glyph, in a tinted tile.
///
/// The fastest thing on a room card to recognise at a glance in a list of five,
/// which is why Landing's resume action wears the same one: the card you picked
/// the room from and the button that resumes it are then visibly the same
/// object, rather than a generic door icon standing in for it.
class MonogramMark extends StatelessWidget {
  const MonogramMark({
    required this.name,
    required this.accent,
    this.size = 44,
    this.strong = false,
    this.child,
    super.key,
  });

  final String name;
  final Color accent;
  final double size;

  /// Loud variant — a selected card, or Landing's hero.
  final bool strong;

  /// Drawn instead of the letter. Used for an archived room's box glyph.
  final Widget? child;

  @override
  Widget build(BuildContext context) {
    final trimmed = name.trim();
    // characters, not code units: a Persian room name's first glyph is not
    // necessarily one UTF-16 unit, and slicing one produces a mojibake box.
    final initial = trimmed.isEmpty
        ? '#'
        : String.fromCharCodes(trimmed.runes.take(1)).toUpperCase();
    return AnimatedContainer(
      duration: AppMotion.card,
      curve: AppMotion.easeOut,
      width: size,
      height: size,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: accent.withValues(alpha: strong ? 0.16 : 0.08),
        borderRadius: BorderRadius.circular(size * 0.32),
        border: Border.all(
          color: accent.withValues(alpha: strong ? 0.7 : 0.25),
        ),
      ),
      child:
          child ??
          Text(
            initial,
            style: TextStyle(
              color: accent,
              fontSize: size * 0.41,
              fontWeight: FontWeight.w900,
            ),
          ),
    );
  }
}
