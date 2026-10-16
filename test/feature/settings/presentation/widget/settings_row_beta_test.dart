import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tark/core/beta/beta_badge.dart';
import 'package:tark/core/beta/beta_feature.dart';
import 'package:tark/core/l10n/app_localizations.dart';
import 'package:tark/feature/settings/presentation/widget/settings_row.dart';

Widget _row({BetaFeature? beta, Locale locale = const Locale('en')}) =>
    MaterialApp(
      locale: locale,
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: Scaffold(
        body: SettingsRow(
          icon: Icons.widgets_rounded,
          label: 'Add the channel widget',
          subtitle: 'Put a dial on your home screen',
          trailing: const Icon(Icons.add_rounded),
          beta: beta,
        ),
      ),
    );

void main() {
  testWidgets('a beta row carries the Beta pill next to its label', (
    tester,
  ) async {
    await tester.pumpWidget(_row(beta: BetaFeature.homeWidget));
    await tester.pumpAndSettle();
    expect(find.byType(BetaPill), findsOneWidget);
    expect(find.text('Add the channel widget'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('an ordinary row has no Beta pill', (tester) async {
    await tester.pumpWidget(_row());
    await tester.pumpAndSettle();
    expect(find.byType(BetaPill), findsNothing);
  });

  testWidgets('the widget beta has its own key and names in both languages', (
    tester,
  ) async {
    expect(BetaFeature.homeWidget.key, 'home_widget');
    for (final lang in ['en', 'fa']) {
      final s = await AppLocalizations.delegate.load(Locale(lang));
      expect(BetaFeature.homeWidget.label(s), isNotEmpty);
    }
  });
}
