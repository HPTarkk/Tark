// GENERATED CODE - DO NOT MODIFY BY HAND
// dart format width=80

// **************************************************************************
// InjectableConfigGenerator
// **************************************************************************

// ignore_for_file: type=lint
// coverage:ignore-file

// ignore_for_file: no_leading_underscores_for_library_prefixes
import 'package:audio_io/audio_io.dart' as _i891;
import 'package:get_it/get_it.dart' as _i174;
import 'package:injectable/injectable.dart' as _i526;
import 'package:tark/app/di/di_config.dart' as _i250;
import 'package:tark/feature/audio/api/audio_api.dart' as _i138;
import 'package:tark/feature/audio/data/audio_engine_impl.dart' as _i876;
import 'package:tark/feature/audio/domain/service/audio_engine.dart' as _i565;
import 'package:tark/feature/landing/presentation/manager/landing_cubit.dart'
    as _i205;
import 'package:tark/feature/transfer/api/transfer_api.dart' as _i430;
import 'package:tark/feature/transfer/data/repository/bluetooth_transfer_repository.dart'
    as _i485;
import 'package:tark/feature/transfer/data/repository/webrtc_transfer_repository.dart'
    as _i482;
import 'package:tark/feature/transfer/data/repository/wifi_transfer_repository_impl.dart'
    as _i627;
import 'package:tark/feature/transfer/data/service/transfer_mode_store_impl.dart'
    as _i290;
import 'package:tark/feature/transfer/domain/repository/bluetooth_transport.dart'
    as _i638;
import 'package:tark/feature/transfer/domain/repository/guest_link_controller.dart'
    as _i945;
import 'package:tark/feature/transfer/domain/repository/transfer_repository.dart'
    as _i923;
import 'package:tark/feature/transfer/domain/service/transfer_mode_store.dart'
    as _i517;
import 'package:tark/feature/transfer/presentation/manager/bluetooth_connect_cubit.dart'
    as _i1058;
import 'package:tark/feature/transfer/presentation/manager/guest_link_cubit.dart'
    as _i1007;
import 'package:tark/feature/transfer/presentation/manager/hotspot_bridge_cubit.dart'
    as _i659;
import 'package:tark/feature/walkie/presentation/manager/walkie_talkie_cubit.dart'
    as _i496;

extension GetItInjectableX on _i174.GetIt {
  // initializes the registration of main-scope dependencies inside of GetIt
  _i174.GetIt init({
    String? environment,
    _i526.EnvironmentFilter? environmentFilter,
  }) {
    final gh = _i526.GetItHelper(this, environment, environmentFilter);
    final registerThirdParty = _$RegisterThirdParty();
    final transferModule = _$TransferModule();
    gh.lazySingleton<_i891.AudioIo>(() => registerThirdParty.audioIo);
    gh.lazySingleton<_i485.BluetoothTransferRepository>(
      () => _i485.BluetoothTransferRepository(),
      dispose: (i) => i.dispose(),
    );
    gh.lazySingleton<_i482.WebRtcTransferRepository>(
      () => _i482.WebRtcTransferRepository(),
      dispose: (i) => i.dispose(),
    );
    gh.lazySingleton<_i627.WifiTransferRepositoryImpl>(
      () => _i627.WifiTransferRepositoryImpl(),
      dispose: (i) => i.dispose(),
    );
    gh.factory<_i659.HotspotBridgeCubit>(
      () => _i659.HotspotBridgeCubit(gh<_i627.WifiTransferRepositoryImpl>()),
    );
    gh.lazySingleton<_i517.TransferModeStore>(
      () => _i290.TransferModeStoreImpl(),
    );
    gh.factory<_i565.AudioEngine>(
      () => _i876.AudioEngineImpl(gh<_i891.AudioIo>()),
    );
    gh.factory<_i205.LandingCubit>(
      () => _i205.LandingCubit(gh<_i430.TransferModeStore>()),
    );
    gh.factory<_i945.GuestLinkController>(
      () => transferModule.guestLinkController(
        gh<_i482.WebRtcTransferRepository>(),
      ),
    );
    gh.factory<_i638.BluetoothTransport>(
      () => transferModule.bluetoothTransport(
        gh<_i485.BluetoothTransferRepository>(),
      ),
    );
    gh.factory<_i923.TransferRepository>(
      () => transferModule.transferRepository(
        gh<_i517.TransferModeStore>(),
        gh<_i627.WifiTransferRepositoryImpl>(),
        gh<_i485.BluetoothTransferRepository>(),
        gh<_i482.WebRtcTransferRepository>(),
      ),
    );
    gh.factory<_i496.WalkieTalkieCubit>(
      () => _i496.WalkieTalkieCubit(
        gh<_i138.AudioEngine>(),
        gh<_i430.TransferRepository>(),
        gh<_i430.TransferModeStore>(),
      ),
    );
    gh.factory<_i1007.GuestLinkCubit>(
      () => _i1007.GuestLinkCubit(gh<_i945.GuestLinkController>()),
    );
    gh.factory<_i1058.BluetoothConnectCubit>(
      () => _i1058.BluetoothConnectCubit(gh<_i638.BluetoothTransport>()),
    );
    return this;
  }
}

class _$RegisterThirdParty extends _i250.RegisterThirdParty {}

class _$TransferModule extends _i250.TransferModule {}
