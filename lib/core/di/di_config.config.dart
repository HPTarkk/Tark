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
import 'package:wakitaki/feature/transfer/data/repository/transfer_repository_impl.dart'
    as _i237;
import 'package:wakitaki/feature/transfer/domain/repository/transfer_repository.dart'
    as _i205;
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
    gh.lazySingleton<_i205.TransferRepository>(
      () => _i237.TransferRepositoryImpl(),
      dispose: (i) => i.dispose(),
    );
    gh.factory<_i7.WalkieTalkieCubit>(
      () => _i7.WalkieTalkieCubit(
        gh<_i891.AudioIo>(),
        gh<_i205.TransferRepository>(),
      ),
    );
    return this;
  }
}

class _$RegisterThirdParty extends _i571.RegisterThirdParty {}
