import 'package:audio_io/audio_io.dart';
import 'package:get_it/get_it.dart';
import 'package:injectable/injectable.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../core/entitlement/billing_service.dart';

import '../../feature/transfer/data/repository/bluetooth_transfer_repository.dart';
import '../../feature/transfer/data/repository/live_transfer_repository.dart';
import '../../feature/transfer/data/repository/webrtc_transfer_repository.dart';
import '../../feature/transfer/domain/repository/bluetooth_transport.dart';
import '../../feature/transfer/domain/repository/guest_link_controller.dart';
import '../../feature/transfer/domain/repository/transfer_repository.dart';
import '../../feature/transfer/domain/repository/wifi_transfer_repository.dart';
import '../../feature/transfer/domain/service/transfer_mode_store.dart';
import 'di_config.config.dart';

@injectableInit
Future<void> configureDependencies() async {
  await GetIt.instance.init();
}

@module
abstract class RegisterThirdParty {
  @lazySingleton
  AudioIo get audioIo => AudioIo.instance;

  /// Resolved exactly once, before the rest of the graph — everything that
  /// persists (SettingsRepository, TransferModeStore, the flow-flag writers)
  /// receives this instance instead of calling getInstance() itself.
  @preResolve
  Future<SharedPreferences> get prefs => SharedPreferences.getInstance();
}

@module
abstract class BillingModule {
  /// No store channel is wired up yet — Bazaar is the only planned one, and
  /// it hasn't landed — so every platform, Android included, takes the stub
  /// and LicenseGate runs unlocked. Resolved once, at graph build time.
  @lazySingleton
  BillingService billingService() => const UnavailableBillingService();
}

@module
abstract class TransferModule {
  BluetoothTransport bluetoothTransport(BluetoothTransferRepository impl) =>
      impl;

  GuestLinkController guestLinkController(WebRtcTransferRepository impl) =>
      impl;

  /// Session-scoped selector used by the live Walkie Cubit.
  ///
  /// The old provider picked a concrete repository once when the Cubit was
  /// created. A Room failover could then update [TransferModeStore.mode] while
  /// the already-running Cubit kept sending on that stale repository. Keep the
  /// Cubit stable instead and let [LiveTransferRepository] replace only the
  /// temporary transport attachment. Wi-Fi/hotspot still share the same live
  /// repository; Bluetooth and Guest reuse their already-connected singletons.
  TransferRepository transferRepository(
    TransferModeStore store,
    WifiTransferRepository wifi,
    BluetoothTransferRepository bluetooth,
    WebRtcTransferRepository webrtc,
  ) => LiveTransferRepository(
    modeStore: store,
    wifi: wifi,
    bluetooth: bluetooth,
    guest: webrtc,
  );
}