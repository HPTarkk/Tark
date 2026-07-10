// Throwaway dev harness for eyeballing the splash redesign in a browser —
// no DI, no audio, no router. Loops the splash forever; tiny corner buttons
// (harness-only, not part of the splash) switch theme and locale.
//
// Run: flutter run -d web-server -t lib/main_splash_preview.dart
import 'package:flutter/material.dart';

import 'core/l10n/app_localizations.dart';
import 'core/theme/app_colors.dart';
import 'core/theme/theme_service.dart';
import 'feature/splash/api/splash_api.dart';

void main() => runApp(const _SplashPreviewApp());

class _SplashPreviewApp extends StatefulWidget {
  const _SplashPreviewApp();

  @override
  State<_SplashPreviewApp> createState() => _SplashPreviewAppState();
}

class _SplashPreviewAppState extends State<_SplashPreviewApp> {
  int _run = 0;
  Locale _locale = const Locale('en');

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      locale: _locale,
      theme: ThemeData(
        fontFamily: 'Vazirmatn',
        brightness: ThemeService.isLight ? Brightness.light : Brightness.dark,
        scaffoldBackgroundColor: AppColors.background,
        useMaterial3: true,
      ),
      home: Stack(
        children: [
          KeyedSubtree(
            key: ValueKey('$_run-${ThemeService.currentMode}-$_locale'),
            child: SplashPage.buildPage(
              onFinished: () async => setState(() => _run++),
            ),
          ),
          Positioned(
            top: 4,
            left: 4,
            child: Row(
              children: [
                TextButton(
                  key: const Key('toggle-theme'),
                  onPressed: () async {
                    await ThemeService.setMode(
                      ThemeService.isLight
                          ? AppThemeMode.dark
                          : AppThemeMode.light,
                    );
                    setState(() {});
                  },
                  child: const Text('theme'),
                ),
                TextButton(
                  key: const Key('toggle-locale'),
                  onPressed: () => setState(
                    () => _locale = _locale.languageCode == 'en'
                        ? const Locale('fa')
                        : const Locale('en'),
                  ),
                  child: const Text('locale'),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
