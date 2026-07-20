import 'package:flutter/material.dart';
import 'package:get_it/get_it.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'app/di/di_config.dart';
import 'app/my_app.dart';
import 'app/router/app_router.dart';
import 'app/router/quick_access.dart';
import 'core/locale/locale_service.dart';
import 'core/router/routes.dart';
import 'core/settings/settings_repository.dart';
import 'core/sfx/sfx_service.dart';
import 'core/theme/theme_service.dart';
import 'feature/transfer/api/transfer_api.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // The one SharedPreferences resolution for the whole process: handed to
  // the pre-DI services here, and registered in the DI graph (see
  // RegisterThirdParty.prefs — getInstance() returns this same cached
  // instance) for everything constructed after configureDependencies().
  final prefs = await SharedPreferences.getInstance();
  LocaleService.initialize(prefs);
  ThemeService.initialize(prefs);
  await Sfx.initialize(prefs);
  // Loads libopus once for the process; on failure the codec transparently
  // falls back to PCM16, so this must never block or crash startup.
  await OpusAudioCodec.ensureInitialized();
  await configureDependencies();
  // Must complete before the first page builds: the DI factory that picks
  // the active TransferRepository reads the persisted mode synchronously.
  final modeStore = GetIt.instance<TransferModeStore>();
  await modeStore.initialize();
  // Same reasoning: AppRouter.router is memoized on first read (inside
  // MyApp's build below), so this must also complete before runApp().
  final skipSplash = await GetIt.instance<SettingsRepository>().getSkipSplash();
  AppRouter.startLocation = skipSplash
      ? QuickAccess.resolveStartLocation(modeStore.mode, prefs)
      : AppRoutes.splashPath;
  runApp(const MyApp());
}
