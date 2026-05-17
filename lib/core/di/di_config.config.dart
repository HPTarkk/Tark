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
import 'package:wakitaki/feature/audio/data/repository/playing_repository_impl.dart'
    as _i1050;
import 'package:wakitaki/feature/audio/data/repository/recording_repository_impl.dart'
    as _i947;
import 'package:wakitaki/feature/audio/domian/repository/playing_repository.dart'
    as _i1021;
import 'package:wakitaki/feature/audio/domian/repository/recording_repository.dart'
    as _i55;
import 'package:wakitaki/feature/audio/domian/service/playing_services.dart'
    as _i79;
import 'package:wakitaki/feature/audio/domian/service/recording_services.dart'
    as _i629;
import 'package:wakitaki/feature/audio/presentation/manager/recording_cubit.dart'
    as _i223;
import 'package:wakitaki/feature/transfer/api/transfer_api.dart' as _i456;
import 'package:wakitaki/feature/transfer/data/repository/transfer_repository_impl.dart'
    as _i237;
import 'package:wakitaki/feature/transfer/domain/repository/transfer_repository.dart'
    as _i205;
import 'package:wakitaki/feature/transfer/domain/services/transfer_services.dart'
    as _i25;

extension GetItInjectableX on _i174.GetIt {
  // initializes the registration of main-scope dependencies inside of GetIt
  _i174.GetIt init({
    String? environment,
    _i526.EnvironmentFilter? environmentFilter,
  }) {
    final gh = _i526.GetItHelper(this, environment, environmentFilter);
    final registerThirdParty = _$RegisterThirdParty();
    gh.lazySingleton<_i891.AudioIo>(() => registerThirdParty.audioIo);
    gh.lazySingleton<_i55.RecordingRepository>(
      () => _i947.RecordingRepositoryImpl(gh<_i891.AudioIo>()),
    );
    gh.lazySingleton<_i205.TransferRepository>(
      () => _i237.TransferRepositoryImpl(),
      dispose: (i) => i.dispose(),
    );
    gh.lazySingleton<_i1021.PlayingRepository>(
      () => _i1050.PlayingRepositoryImpl(gh<_i891.AudioIo>()),
    );
    gh.lazySingleton<_i629.RecordingServices>(
      () => _i629.RecordingServices(gh<_i55.RecordingRepository>()),
    );
    gh.lazySingleton<_i456.TransferApi>(
      () => _i456.TransferApi(gh<_i205.TransferRepository>()),
    );
    gh.lazySingleton<_i25.TransferServices>(
      () => _i25.TransferServices(gh<_i205.TransferRepository>()),
    );
    gh.lazySingleton<_i79.PlayingServices>(
      () => _i79.PlayingServices(gh<_i1021.PlayingRepository>()),
    );
    gh.factory<_i223.RecordingCubit>(
      () => _i223.RecordingCubit(
        gh<_i629.RecordingServices>(),
        gh<_i456.TransferApi>(),
      ),
    );
    return this;
  }
}

class _$RegisterThirdParty extends _i571.RegisterThirdParty {}
