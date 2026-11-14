import 'package:flutter_test/flutter_test.dart';
import 'package:tark/core/l10n/app_localizations_en.dart';
import 'package:tark/core/l10n/app_localizations_fa.dart';

void main() {
  // The diagnostics card passes (used, max). Without placeholder metadata the
  // generator ordered the parameters alphabetically, (max, used), and the
  // card read "8 MB of 37.2 KB used".
  test('log usage keeps the used amount first in English', () {
    expect(
      AppLocalizationsEn().settings_log_usage('37.2 KB', '8 MB'),
      '37.2 KB of 8 MB used',
    );
  });

  test('log usage keeps the used amount first in Persian', () {
    expect(
      AppLocalizationsFa().settings_log_usage('۳۷٫۲ KB', '۸ MB'),
      '۳۷٫۲ KB از ۸ MB پر شده',
    );
  });
}
