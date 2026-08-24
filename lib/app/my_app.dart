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
    _launchSub = GetIt.instance<HomeWidgetService>().launches.listen((launch) {
      AppRouter.router.go(
        QuickAccess.locationForLaunch(
          launch,
          GetIt.instance<TransferModeStore>().mode,
        ),
      );
    });
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
    unawaited(GetIt.instance<HomeWidgetService>().refresh());
  }

  @override
  Widget build(BuildContext context) {
    final locale = LocaleService.currentLocale;
    return MaterialApp.router(
      routerConfig: AppRouter.router,
      debugShowCheckedModeBanner: false,
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
