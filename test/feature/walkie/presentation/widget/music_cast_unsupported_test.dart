import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tark/core/l10n/app_localizations.dart';
import 'package:tark/core/l10n/app_localizations_en.dart';
import 'package:tark/core/l10n/app_localizations_fa.dart';
import 'package:tark/feature/walkie/presentation/widget/music_cast_section.dart';

void main() {
  Future<void> pumpUnsupported(
    WidgetTester tester, {
    required Locale locale,
  }) async {
    tester.view.physicalSize = const Size(320, 640);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      MaterialApp(
        locale: locale,
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(
          body: SizedBox(
            width: 320,
            child: MusicCastSection(
              supportedForTest: Future<bool>.value(false),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('unsupported capture remains visible and cannot start sharing', (
    tester,
  ) async {
    await pumpUnsupported(tester, locale: const Locale('en'));

    expect(
      find.text(AppLocalizationsEn().preflight_shared_music_unavailable),
      findsOneWidget,
    );
    expect(find.text(AppLocalizationsEn().music_cast), findsOneWidget);
    expect(find.text(AppLocalizationsEn().music_cast_start), findsNothing);
    expect(find.byIcon(Icons.music_off_rounded), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('unsupported state is localized in Persian RTL at 320px', (
    tester,
  ) async {
    await pumpUnsupported(tester, locale: const Locale('fa'));

    expect(
      find.text(AppLocalizationsFa().preflight_shared_music_unavailable),
      findsOneWidget,
    );
    final directionality = tester.widget<Directionality>(
      find.byType(Directionality).first,
    );
    expect(directionality.textDirection, TextDirection.rtl);
    expect(find.text(AppLocalizationsFa().music_cast_start), findsNothing);
    expect(tester.takeException(), isNull);
  });
}
