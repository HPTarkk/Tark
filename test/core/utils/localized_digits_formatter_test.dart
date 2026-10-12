import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tark/core/utils/localized_digits_formatter.dart';

TextEditingValue _typed(String text, {TextRange composing = TextRange.empty}) =>
    TextEditingValue(
      text: text,
      selection: TextSelection.collapsed(offset: text.length),
      composing: composing,
    );

void main() {
  group('LocaleDigitsFormatter', () {
    const fa = LocaleDigitsFormatter(farsi: true);
    const en = LocaleDigitsFormatter(farsi: false);

    test('Persian shows Latin and Arabic-Indic digits as Persian', () {
      final out = fa.formatEditUpdate(_typed('سفر'), _typed('سفر 2٣'));
      expect(out.text, 'سفر ۲۳');
    });

    test('English shows Persian and Arabic-Indic digits as Latin', () {
      final out = en.formatEditUpdate(_typed('Ride'), _typed('Ride ۲٣'));
      expect(out.text, 'Ride 23');
    });

    test('keeps the caret and selection exactly where they were', () {
      const before = TextEditingValue(
        text: 'a1b',
        selection: TextSelection(baseOffset: 1, extentOffset: 2),
      );
      final out = fa.formatEditUpdate(TextEditingValue.empty, before);
      expect(out.text, 'a۱b');
      expect(out.selection, before.selection);
    });

    test('leaves text without digits untouched (same instance)', () {
      final value = _typed('بدون عدد');
      expect(identical(fa.formatEditUpdate(value, value), value), isTrue);
    });

    test('does not rewrite the span the keyboard is still composing', () {
      final value = _typed(
        '12 ab3',
        composing: const TextRange(start: 3, end: 6),
      );
      final out = fa.formatEditUpdate(TextEditingValue.empty, value);
      expect(out.text, '۱۲ ab3');
      expect(out.composing, value.composing);
      // Once committed, the rest follows.
      final committed = fa.formatEditUpdate(out, _typed(out.text));
      expect(committed.text, '۱۲ ab۳');
    });

    testWidgets('.of reads the app language', (tester) async {
      late LocaleDigitsFormatter formatter;
      await tester.pumpWidget(
        Localizations(
          locale: const Locale('fa'),
          delegates: const [DefaultWidgetsLocalizations.delegate],
          child: Builder(
            builder: (context) {
              formatter = LocaleDigitsFormatter.of(context);
              return const SizedBox();
            },
          ),
        ),
      );
      expect(formatter.farsi, isTrue);
    });
  });

  group('anyDigitsOnly', () {
    String filter(TextInputFormatter formatter, String text) =>
        formatter.formatEditUpdate(TextEditingValue.empty, _typed(text)).text;

    test('accepts every digit set and nothing else', () {
      expect(filter(anyDigitsOnly, '۱2٣ a-b'), '۱2٣');
    });

    test('is the fix for digitsOnly, which drops a Persian keypad', () {
      expect(filter(FilteringTextInputFormatter.digitsOnly, '۱۲۳'), '');
      expect(filter(anyDigitsOnly, '۱۲۳'), '۱۲۳');
    });
  });
}
