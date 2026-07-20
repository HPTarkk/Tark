/// Composition root for the guest web build.
///
/// main_guest.dart never calls configureDependencies() — most of the app's
/// DI graph pulls in dart:io transports that can't compile on web — so the
/// concrete wiring GetIt does for the app happens here instead. This file is
/// the only place the guest feature touches data-layer constructors;
/// presentation depends on the abstractions these factories return.
library;

import 'package:audio_io/audio_io.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../../core/settings/settings_repository_impl.dart';
import '../../../core/sfx/sfx_player.dart';
import '../../audio/data/audio_engine_impl.dart';
import '../../transfer/data/codec/waki_packet_codec.dart';
import '../data/guest_web_client.dart';
import '../presentation/manager/guest_session_cubit.dart';

/// The guest process's single SharedPreferences resolution, handed in by
/// main_guest.dart before the first page builds.
late final SharedPreferences _prefs;

void initializeGuestComposition(SharedPreferences prefs) {
  _prefs = prefs;
}

GuestWebClient createGuestWebClient() => GuestWebClient();

GuestSessionCubit createGuestSessionCubit(GuestWebClient client) {
  final settings = SettingsRepositoryImpl(_prefs);
  return GuestSessionCubit(
    client,
    engine: AudioEngineImpl(AudioIo.instance, settings),
    settingsRepository: settings,
    codec: WakiPacketCodec(),
    sfx: const SfxServicePlayer(),
  );
}
