import 'package:audio_io/audio_io.dart';
import 'package:get_it/get_it.dart';
import 'package:injectable/injectable.dart';

import '../../feature/transfer/data/repository/bluetooth_transfer_repository.dart';
import '../../feature/transfer/data/repository/webrtc_transfer_repository.dart';
import '../../feature/transfer/data/repository/wifi_transfer_repository_impl.dart';
import '../../feature/transfer/domain/entity/transfer_mode.dart';
import '../../feature/transfer/domain/repository/bluetooth_transport.dart';
import '../../feature/transfer/domain/repository/guest_link_controller.dart';
import '../../feature/transfer/domain/repository/transfer_repository.dart';
import '../../feature/transfer/domain/service/transfer_mode_store.dart';
import 'di_config.config.dart';

@injectableInit
void configureDependencies() {
  GetIt.instance.init();
}

@module
abstract class RegisterThirdParty {
  @lazySingleton
  AudioIo get audioIo => AudioIo.instance;
}

@module
abstract class TransferModule {
  BluetoothTransport bluetoothTransport(BluetoothTransferRepository impl) =>
      impl;

  GuestLinkController guestLinkController(WebRtcTransferRepository impl) =>
      impl;

  /// Selector, not a fixed binding: WalkieTalkieCubit (a factory) resolves
  /// TransferRepository fresh each time it's built, so this picks whichever
  /// transport singleton is active per [TransferModeStore.mode] — for
  /// Bluetooth/Guest that's the already-connected instance from the
  /// connect screen, not a new connection attempt.
  TransferRepository transferRepository(
    TransferModeStore store,
    WifiTransferRepositoryImpl wifi,
    BluetoothTransferRepository bluetooth,
    WebRtcTransferRepository webrtc,
  ) =>
      switch (store.mode) {
        TransferMode.bluetooth => bluetooth,
        TransferMode.guest => webrtc,
        // Hotspot mode is only a Wi-Fi *setup* step (Android hosts a local AP
        // the iPhone joins); the audio session itself is plain Wi-Fi.
        TransferMode.hotspot => wifi,
        TransferMode.wifi => wifi,
      };
}
