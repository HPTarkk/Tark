import 'package:audio_io/audio_io.dart';
import 'package:injectable/injectable.dart';

@injectableInit
void configureDependencies() {}

@module
abstract class RegisterThirdParty {
  @lazySingleton
  AudioIo get audioIo => AudioIo.instance;
}
