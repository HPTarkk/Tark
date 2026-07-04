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
import 'package:tark/app/di/di_config.dart' as _i428;
import 'package:tark/feature/audio/api/audio_api.dart' as _i565;
import 'package:tark/feature/audio/data/audio_engine_impl.dart' as _i348;
import 'package:tark/feature/audio/domain/service/audio_engine.dart'
    as _i464;
import 'package:tark/feature/landing/presentation/manager/landing_cubit.dart'
    as _i729;
import 'package:tark/feature/transfer/api/transfer_api.dart' as _i456;
import 'package:tark/feature/transfer/data/repository/bluetooth_transfer_repository.dart'
    as _i1028;
import 'package:tark/feature/transfer/data/repository/wifi_transfer_repository_impl.dart'
    as _i156;
import 'package:tark/feature/transfer/data/service/transfer_mode_store_impl.dart'
    as _i520;
import 'package:tark/feature/transfer/domain/repository/bluetooth_transport.dart'
    as _i413;
import 'package:tark/feature/transfer/domain/repository/transfer_repository.dart'
    as _i205;
import 'package:tark/feature/transfer/domain/service/transfer_mode_store.dart'
    as _i925;
import 'package:tark/feature/transfer/presentation/manager/bluetooth_connect_cubit.dart'
    as _i512;
import 'package:tark/feature/walkie/presentation/manager/walkie_talkie_cubit.dart'
    as _i7;

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
    gh.lazySingleton<_i1028.BluetoothTransferRepository>(
      () => _i1028.BluetoothTransferRepository(),
      dispose: (i) => i.dispose(),
    );
    gh.lazySingleton<_i156.WifiTransferRepositoryImpl>(
      () => _i156.WifiTransferRepositoryImpl(),
      dispose: (i) => i.dispose(),
    );
    gh.lazySingleton<_i925.TransferModeStore>(
      () => _i520.TransferModeStoreImpl(),
    );
    gh.factory<_i464.AudioEngine>(
      () => _i348.AudioEngineImpl(gh<_i891.AudioIo>()),
    );
    gh.factory<_i413.BluetoothTransport>(
      () => transferModule.bluetoothTransport(
        gh<_i1028.BluetoothTransferRepository>(),
      ),
    );
    gh.factory<_i205.TransferRepository>(
      () => transferModule.transferRepository(
        gh<_i925.TransferModeStore>(),
        gh<_i156.WifiTransferRepositoryImpl>(),
        gh<_i1028.BluetoothTransferRepository>(),
      ),
    );
    gh.factory<_i729.LandingCubit>(
      () => _i729.LandingCubit(gh<_i456.TransferModeStore>()),
    );
    gh.factory<_i512.BluetoothConnectCubit>(
      () => _i512.BluetoothConnectCubit(gh<_i413.BluetoothTransport>()),
    );
    gh.factory<_i7.WalkieTalkieCubit>(
      () => _i7.WalkieTalkieCubit(
        gh<_i565.AudioEngine>(),
        gh<_i456.TransferRepository>(),
        gh<_i456.TransferModeStore>(),
      ),
    );
    return this;
  }
}

class _$RegisterThirdParty extends _i428.RegisterThirdParty {}

class _$TransferModule extends _i428.TransferModule {}
