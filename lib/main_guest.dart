import 'package:flutter/material.dart';

import 'core/l10n/app_localizations.dart';
import 'core/locale/locale_service.dart';
import 'core/sfx/sfx_service.dart';
import 'core/theme/app_colors.dart';
import 'core/theme/theme_service.dart';
// Direct file import (not the transfer barrel): the barrel exports pages
// that use dart:io, which cannot compile on web.
import 'feature/guest/presentation/page/guest_join_page.dart';
import 'feature/transfer/data/codec/opus_audio_codec.dart';

/// Web guest entrypoint. Build with:
///   flutter build web --release -t lib/main_guest.dart
/// (or scripts/build-web-release.ps1) and host the output on any static
/// HTTPS host; the invite QR in the app points guests at it (see
/// core/config/guest_config.dart).
void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await LocaleService.initialize();
  await ThemeService.initialize();
  await Sfx.initialize();
  // Best effort: when the wasm build of libopus fails to load, the codec
  // falls back to PCM16 — a WebRTC data channel on LAN has the headroom.
  await OpusAudioCodec.ensureInitialized();
  runApp(const GuestApp());
}

class GuestApp extends StatefulWidget {
  const GuestApp({super.key});

  @override
  State<GuestApp> createState() => _GuestAppState();
}

class _GuestAppState extends State<GuestApp> {
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
    super.dispose();
  }

  void _onAppSettingChanged() => setState(() {});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Tark Guest',
      debugShowCheckedModeBanner: false,
      locale: LocaleService.currentLocale,
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
      // AppColors resolves statically; re-key the tree on theme change so
      // const subtrees pick up the new palette (same trick as the app).
      builder: (context, child) => KeyedSubtree(
        key: ValueKey(ThemeService.currentMode),
        child: child!,
      ),
      theme: ThemeData(
        fontFamily: 'Vazirmatn',
        brightness: ThemeService.isLight ? Brightness.light : Brightness.dark,
        scaffoldBackgroundColor: AppColors.background,
        useMaterial3: true,
      ),
      home: const GuestJoinPage(),
    );
  }
}
