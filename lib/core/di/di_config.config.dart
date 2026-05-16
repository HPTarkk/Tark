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
import 'package:wakitaki/feature/recording/data/repository/recording_repository_impl.dart'
    as _i615;
import 'package:wakitaki/feature/recording/domian/repository/recording_repository.dart'
    as _i767;
import 'package:wakitaki/feature/recording/domian/service/recording_services.dart'
    as _i149;
import 'package:wakitaki/feature/recording/presentation/manager/recording_cubit.dart'
    as _i380;

extension GetItInjectableX on _i174.GetIt {
  // initializes the registration of main-scope dependencies inside of GetIt
  _i174.GetIt init({
    String? environment,
    _i526.EnvironmentFilter? environmentFilter,
  }) {
    final gh = _i526.GetItHelper(this, environment, environmentFilter);
    final registerThirdParty = _$RegisterThirdParty();
    gh.lazySingleton<_i891.AudioIo>(() => registerThirdParty.audioIo);
    gh.lazySingleton<_i767.RecordingRepository>(
      () => _i615.RecordingRepositoryImpl(gh<_i891.AudioIo>()),
    );
    gh.lazySingleton<_i149.RecordingServices>(
      () => _i149.RecordingServices(gh<_i767.RecordingRepository>()),
    );
    gh.factory<_i380.RecordingCubit>(
      () => _i380.RecordingCubit(gh<_i149.RecordingServices>()),
    );
    return this;
  }
}

class _$RegisterThirdParty extends _i571.RegisterThirdParty {}
