import 'package:audio_io/audio_io.dart';
import 'package:flutter/cupertino.dart' show CupertinoPageTransitionsBuilder;
import 'package:flutter/material.dart';
import 'package:get_it/get_it.dart';

import '../core/l10n/app_localizations.dart';
import '../core/l10n/extension.dart';
import '../core/locale/locale_service.dart';
import '../core/theme/app_colors.dart';
import '../core/theme/theme_service.dart';
import '../core/widget/theme_reveal_transition.dart';
import 'router/app_router.dart';

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
      // colors. Re-keying the subtree on theme change forces a rebuild;
      // GoRouter keeps the current location, so navigation is unaffected.
      //
      // CAVEAT: this is NOT a full re-inflation. GoRouter's navigator holds
      // a GlobalKey, so the old element tree is grafted back, and grafted
      // elements only re-dirty if they depend on an InheritedWidget (Theme,
      // MediaQuery, Localizations, a Bloc/Provider, ...). A build that reads
      // ONLY static AppColors never rebuilds and keeps the old palette until
      // its element is recreated — such widgets must listen to
      // ThemeService.mode themselves (see _ScanlineBackground in
      // VisualizerSection and _BrandBadge in WalkieHeader).
      // The RepaintBoundary is what AppRevealController snapshots for the
      // circular-reveal transition (item 10) — kept in addition to, not
      // instead of, the KeyedSubtree re-key above.
      builder: (context, child) => RepaintBoundary(
        key: AppRevealController.repaintBoundaryKey,
        child: KeyedSubtree(
          key: ValueKey(ThemeService.currentMode),
          child: child!,
        ),
      ),
      locale: locale,
      localizationsDelegates: const [
        ...AppLocalizations.localizationsDelegates,
      ],
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
        // M3 snackbars default to inverseSurface/onInverseSurface, which
        // clashes with our card-colored backgrounds; pin both sides here so
        // every SnackBar is card + readable text without per-call overrides.
        snackBarTheme: SnackBarThemeData(
          backgroundColor: AppColors.card,
          contentTextStyle: TextStyle(
            fontFamily: 'Vazirmatn',
            color: AppColors.textPrimary,
            fontSize: 14,
          ),
          actionTextColor: AppColors.amber,
        ),
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
