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
import 'package:wakitaki/core/di/di_config.dart' as _i571;
import 'package:wakitaki/core/transfer/transfer_mode_holder.dart' as _i812;
import 'package:wakitaki/feature/audio/presentation/manager/audio_cubit.dart'
    as _i42;
import 'package:wakitaki/feature/transfer/data/repository/bluetooth_transfer_repository.dart'
    as _i118;
import 'package:wakitaki/feature/transfer/data/repository/wifi_transfer_repository_impl.dart'
    as _i237;
import 'package:wakitaki/feature/transfer/domain/entity/transfer_mode.dart'
    as _i603;
import 'package:wakitaki/feature/transfer/domain/repository/bluetooth_transport.dart'
    as _i699;
import 'package:wakitaki/feature/transfer/domain/repository/transfer_repository.dart'
    as _i205;
import 'package:wakitaki/feature/transfer/presentation/manager/bluetooth_connect_cubit.dart'
    as _i340;
import 'package:wakitaki/feature/walkie/presentation/manager/walkie_talkie_cubit.dart'
    as _i7;

extension GetItInjectableX on _i174.GetIt {
  // initializes the registration of main-scope dependencies inside of GetIt
  _i174.GetIt init({
    String? environment,
    _i526.EnvironmentFilter? environmentFilter,
  }) {
    final gh = _i526.GetItHelper(this, environment, environmentFilter);
    final registerThirdParty = _$RegisterThirdParty();
    gh.lazySingleton<_i891.AudioIo>(() => registerThirdParty.audioIo);
    gh.lazySingleton<_i237.WifiTransferRepositoryImpl>(
      () => _i237.WifiTransferRepositoryImpl(),
      dispose: (i) => i.dispose(),
    );
    gh.lazySingleton<_i118.BluetoothTransferRepository>(
      () => _i118.BluetoothTransferRepository(),
      dispose: (i) => i.dispose(),
    );
    gh.lazySingleton<_i699.BluetoothTransport>(
      () => gh<_i118.BluetoothTransferRepository>(),
    );
    // Selector, not a fixed binding: WalkieTalkieCubit (a factory) resolves
    // TransferRepository fresh each time it's built, so this picks whichever
    // transport singleton is active per _i812.TransferModeHolder.mode — for
    // Bluetooth that's the already-connected instance from the Host/Join
    // screen, not a new connection attempt.
    gh.factory<_i205.TransferRepository>(
      () => _i812.TransferModeHolder.mode == _i603.TransferMode.bluetooth
          ? gh<_i118.BluetoothTransferRepository>()
          : gh<_i237.WifiTransferRepositoryImpl>(),
    );
    gh.factory<_i42.AudioCubit>(() => _i42.AudioCubit(gh<_i891.AudioIo>()));
    gh.factory<_i340.BluetoothConnectCubit>(
      () => _i340.BluetoothConnectCubit(gh<_i699.BluetoothTransport>()),
    );
    gh.factory<_i7.WalkieTalkieCubit>(
      () => _i7.WalkieTalkieCubit(
        gh<_i42.AudioCubit>(),
        gh<_i205.TransferRepository>(),
      ),
    );
    return this;
  }
}

class _$RegisterThirdParty extends _i571.RegisterThirdParty {}
