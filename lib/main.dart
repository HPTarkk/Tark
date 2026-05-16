import 'package:audio_io/audio_io.dart';
import 'package:flutter/material.dart';
import 'package:get_it/get_it.dart';

import 'core/di/di_config.dart';
import 'core/l10n/app_localizations.dart';
import 'core/l10n/extension.dart';
import 'core/router/app_router.dart';

void main() {
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
  void dispose() {
    GetIt.instance<AudioIo>().dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp.router(
      routerConfig: AppRouter.router,
      locale: const Locale('fa', 'IR'),
      localizationsDelegates: const [...AppLocalizations.localizationsDelegates],
      supportedLocales: AppLocalizations.supportedLocales,
      localeResolutionCallback: (locale, supportedLocales) => locale,
      onGenerateTitle: (context) => context.getString.app_name,
      theme: ThemeData(colorScheme: .fromSeed(seedColor: Colors.brown)),
    );
  }
}
