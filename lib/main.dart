import 'package:audio_io/audio_io.dart';
import 'package:flutter/cupertino.dart' show CupertinoPageTransitionsBuilder;
import 'package:flutter/material.dart';
import 'package:get_it/get_it.dart';

import 'core/di/di_config.dart';
import 'core/l10n/app_localizations.dart';
import 'core/l10n/extension.dart';
import 'core/locale/locale_service.dart';
import 'core/router/app_router.dart';
import 'core/transfer/transfer_mode_holder.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await LocaleService.initialize();
  await TransferModeHolder.initialize();
  configureDependencies();
  runApp(const MyApp());
}

class MyApp extends StatefulWidget {
  const MyApp({super.key});

  @override
  State<MyApp> createState() => _MyAppState();
}

class _MyAppState extends State<MyApp> {
  @override
  void initState() {
    super.initState();
    LocaleService.locale.addListener(_onLocaleChanged);
  }

  @override
  void dispose() {
    LocaleService.locale.removeListener(_onLocaleChanged);
    GetIt.instance<AudioIo>().dispose();
    super.dispose();
  }

  void _onLocaleChanged() => setState(() {});

  @override
  Widget build(BuildContext context) {
    final locale = LocaleService.currentLocale;
    return MaterialApp.router(
      routerConfig: AppRouter.router,
      debugShowCheckedModeBanner: false,
      locale: locale,
      localizationsDelegates: const [...AppLocalizations.localizationsDelegates],
      supportedLocales: AppLocalizations.supportedLocales,
      localeResolutionCallback: (deviceLocale, supported) {
        for (final sl in supported) {
          if (sl.languageCode == deviceLocale?.languageCode) return sl;
        }
        return supported.first;
      },
      onGenerateTitle: (context) => context.getString.app_name,
      theme: ThemeData(
        fontFamily: 'Vazirmatn',
        brightness: Brightness.dark,
        scaffoldBackgroundColor: const Color(0xFF080B14),
        colorScheme: const ColorScheme.dark(
          primary: Color(0xFFFFB74D),
          secondary: Color(0xFF4CAF50),
          surface: Color(0xFF0F1320),
          error: Color(0xFFEF5350),
        ),
        useMaterial3: true,
        pageTransitionsTheme: const PageTransitionsTheme(
          builders: {
            TargetPlatform.android: CupertinoPageTransitionsBuilder(),
            TargetPlatform.iOS: CupertinoPageTransitionsBuilder(),
            TargetPlatform.windows: CupertinoPageTransitionsBuilder(),
            TargetPlatform.linux: CupertinoPageTransitionsBuilder(),
            TargetPlatform.macOS: CupertinoPageTransitionsBuilder(),
          },
        ),
      ),
    );
  }
}
