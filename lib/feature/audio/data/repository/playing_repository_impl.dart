import 'package:audio_io/audio_io.dart';
import 'package:injectable/injectable.dart';

import '../../../../core/utils/logger.dart';
import '../../domian/entity/recorded_audio_data.dart';
import '../../domian/repository/playing_repository.dart';

@LazySingleton(as: PlayingRepository)
class PlayingRepositoryImpl implements PlayingRepository {
  final AudioIo _audioIo;
  const PlayingRepositoryImpl(this._audioIo);

  @override
  Future<void> playAudio(RecordedAudioData data) async {
    try {
      _audioIo.output.add(data.sampleData);
    } catch (error) {
      Logger.log(error);
    }
  }
}
