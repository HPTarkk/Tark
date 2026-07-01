import 'package:audio_io/audio_io.dart';
import 'package:flutter/cupertino.dart' show CupertinoPageTransitionsBuilder;
import 'package:flutter/material.dart';
import 'package:get_it/get_it.dart';

import 'core/di/di_config.dart';
import 'core/l10n/app_localizations.dart';
import 'core/l10n/extension.dart';
import 'core/locale/locale_service.dart';
import 'core/router/app_router.dart';
import 'core/theme/app_colors.dart';
import 'core/theme/theme_service.dart';
import 'core/transfer/transfer_mode_holder.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await LocaleService.initialize();
  await ThemeService.initialize();
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
    LocaleService.locale.addListener(_onAppSettingChanged);
    ThemeService.mode.addListener(_onAppSettingChanged);
  }

  @override
  void dispose() {
    LocaleService.locale.removeListener(_onAppSettingChanged);
    ThemeService.mode.removeListener(_onAppSettingChanged);
    GetIt.instance<AudioIo>().dispose();
    super.dispose();
  }

  void _onAppSettingChanged() => setState(() {});

  @override
  Widget build(BuildContext context) {
    final locale = LocaleService.currentLocale;
    return MaterialApp.router(
      routerConfig: AppRouter.router,
      debugShowCheckedModeBanner: false,
      // AppColors resolves statically (no InheritedWidget dependency), so
      // const widget subtrees would be skipped on rebuild and keep stale
      // colors. Re-keying the subtree on theme change forces a full rebuild;
      // GoRouter keeps the current location, so navigation is unaffected.
      builder: (context, child) => KeyedSubtree(
        key: ValueKey(ThemeService.currentMode),
        child: child!,
      ),
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
        brightness: ThemeService.isLight ? Brightness.light : Brightness.dark,
        scaffoldBackgroundColor: AppColors.background,
        colorScheme: ThemeService.isLight
            ? ColorScheme.light(
                primary: AppColors.amber,
                secondary: AppColors.green,
                surface: AppColors.surface,
                error: AppColors.red,
              )
            : ColorScheme.dark(
                primary: AppColors.amber,
                secondary: AppColors.green,
                surface: AppColors.surface,
                error: AppColors.red,
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
