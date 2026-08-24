import 'dart:async';

import 'package:audio_io/audio_io.dart';
import 'package:flutter/material.dart';
import 'package:get_it/get_it.dart';

import '../core/home_widget/home_widget_launch.dart';
import '../core/home_widget/home_widget_service.dart';
import '../core/home_widget/widget_control_channel.dart';
import '../core/l10n/app_localizations.dart';
import '../core/l10n/extension.dart';
import '../core/locale/locale_service.dart';
import '../core/router/routes.dart';
import '../core/theme/app_colors.dart';
import '../core/theme/theme_service.dart';
import '../core/widget/theme_reveal_transition.dart';
import '../feature/transfer/api/transfer_api.dart';
import 'router/app_router.dart';
import 'router/quick_access.dart';

class MyApp extends StatefulWidget {
  const MyApp({super.key});

  @override
  State<MyApp> createState() => _MyAppState();
}

class _MyAppState extends State<MyApp> {
  StreamSubscription<HomeWidgetLaunch>? _launchSub;
  StreamSubscription<WidgetControlAction>? _controlSub;

  @override
  void initState() {
    super.initState();
    LocaleService.locale.addListener(_onAppSettingChanged);
    ThemeService.mode.addListener(_onAppSettingChanged);
    // Taps that land while the process is already alive. The cold-start tap
    // is handled in main.dart instead, by picking the router's initial
    // location — routing it through here would push a second page on top of
    // whatever the normal start-up decision had already built.
    _launchSub = GetIt.instance<HomeWidgetService>().launches.listen((launch) {
      AppRouter.router.go(
        QuickAccess.locationForLaunch(
          launch,
          GetIt.instance<TransferModeStore>().mode,
        ),
      );
    });
    // END on the widget. Handled here rather than in WalkieTalkieCubit
    // because leaving the channel *is* the navigation: routing to Landing
    // disposes the cubit, and its close() is what tears the session,
    // transport and keep-alive service down. MUTE stays in the cubit, which
    // owns that state.
    _controlSub = GetIt.instance<WidgetControlChannel>().actions.listen((
      action,
    ) {
      if (action == WidgetControlAction.endSession) {
        AppRouter.router.go(AppRoutes.landingPath);
      }
    });
  }

  @override
  void dispose() {
    LocaleService.locale.removeListener(_onAppSettingChanged);
    ThemeService.mode.removeListener(_onAppSettingChanged);
    _launchSub?.cancel();
    _controlSub?.cancel();
    GetIt.instance<AudioIo>().dispose();
    super.dispose();
  }

  void _onAppSettingChanged() {
    setState(() {});
    // The widget renders its strings localized and its colors themed at
    // publish time, so a language or theme switch has to be pushed to it
    // explicitly — nothing about the session changed, so nothing else would
    // republish, and the home screen would keep the old language until the
    // next session event.
    unawaited(GetIt.instance<HomeWidgetService>().refresh());
  }

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
