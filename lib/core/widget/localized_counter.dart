import 'package:flutter/material.dart';

import '../utils/extensions.dart';

/// A character counter for [TextField] that counts in the reader's numerals.
///
/// R13 swept every quantity this app renders onto Persian digits and could not
/// have reached this one: the counter string is not built here. Flutter's
/// `TextField._getEffectiveDecoration` composes it with bare interpolation —
/// `var counterText = '$currentLength'`, then `counterText += '/${maxLength}'`
/// — so it is ASCII whatever the locale says, and no sweep over this codebase
/// would ever have found it. [TextField.buildCounter] is the framework's own
/// hook for exactly this, and it is the only way in.
///
/// **The screen reader keeps its sentence.** Supplying `buildCounter` makes
/// the framework return early, before it sets `semanticCounterText` — so the
/// naive fix trades "۳/۱۲ is readable" for "a blind user stops being told how
/// many characters are left", which is not a trade. The label is rebuilt here
/// from the same [MaterialLocalizations] string the framework would have used,
/// and the digits are hidden behind it exactly as [InputDecorator] does.
///
/// The visual run is pinned left-to-right. Persian writes numbers that way
/// inside otherwise right-to-left text, and without it «۳/۱۲» is free to come
/// out as «۱۲/۳» — a counter that reads as though the field were already over
/// its limit. This only orders the glyphs; which side of the field the counter
/// sits on is still the decorator's business, and still follows the locale.
InputCounterWidgetBuilder localizedCounter({TextStyle? style}) =>
    (
      BuildContext context, {
      required int currentLength,
      required int? maxLength,
      required bool isFocused,
    }) {
      // Same three cases the framework has, in the same order. A field with no
      // limit has nothing to count towards, and a non-positive limit is
      // Flutter's way of saying "count, but do not cap".
      if (maxLength == null) return null;
      final farsi = Localizations.localeOf(context).languageCode == 'fa';
      final counted = maxLength > 0
          ? '$currentLength/$maxLength'
          : '$currentLength';
      final remaining = maxLength > 0
          ? (maxLength - currentLength).clamp(0, maxLength)
          : null;

      return Text(
        localizeDigits(counted, farsi: farsi),
        textDirection: TextDirection.ltr,
        semanticsLabel: remaining == null
            ? null
            : MaterialLocalizations.of(
                context,
              ).remainingTextFieldCharacterCount(remaining),
        style:
            style ??
            Theme.of(context).inputDecorationTheme.counterStyle ??
            Theme.of(context).textTheme.bodySmall,
      );
    };
