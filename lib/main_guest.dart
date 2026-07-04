import 'package:flutter/material.dart';

import 'core/theme/app_colors.dart';
import 'core/theme/theme_service.dart';
// Direct file import (not the transfer barrel): the barrel exports pages
// that use dart:io, which cannot compile on web.
import 'feature/guest/presentation/page/guest_join_page.dart';
import 'feature/transfer/data/codec/opus_audio_codec.dart';

/// Web guest entrypoint. Build with:
///   flutter build web --release -t lib/main_guest.dart
/// and host the output on any static HTTPS host; the invite QR in the app
/// points guests at it (see core/config/guest_config.dart).
void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await ThemeService.initialize();
  // Best effort: when the wasm build of libopus fails to load, the codec
  // falls back to PCM16 — a WebRTC data channel on LAN has the headroom.
  await OpusAudioCodec.ensureInitialized();
  runApp(const GuestApp());
}

class GuestApp extends StatelessWidget {
  const GuestApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Tark Guest',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        brightness: ThemeService.isLight ? Brightness.light : Brightness.dark,
        scaffoldBackgroundColor: AppColors.background,
        useMaterial3: true,
      ),
      home: const GuestJoinPage(),
    );
  }
}
