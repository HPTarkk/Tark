import 'package:audio_io/audio_io.dart';
import 'package:get_it/get_it.dart';
import 'package:injectable/injectable.dart';

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
