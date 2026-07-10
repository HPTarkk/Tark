import 'package:flutter/material.dart';
import 'package:get_it/get_it.dart';

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
  await LocaleService.initialize();
  await ThemeService.initialize();
  await Sfx.initialize();
  // Loads libopus once for the process; on failure the codec transparently
  // falls back to PCM16, so this must never block or crash startup.
  await OpusAudioCodec.ensureInitialized();
  configureDependencies();
  // Must complete before the first page builds: the DI factory that picks
  // the active TransferRepository reads the persisted mode synchronously.
  final modeStore = GetIt.instance<TransferModeStore>();
  await modeStore.initialize();
  // Same reasoning: AppRouter.router is memoized on first read (inside
  // MyApp's build below), so this must also complete before runApp().
  final skipSplash = await GetIt.instance<SettingsRepository>().getSkipSplash();
  AppRouter.startLocation = skipSplash
      ? await QuickAccess.resolveStartLocation(modeStore.mode)
      : AppRoutes.splashPath;
  runApp(const MyApp());
}
