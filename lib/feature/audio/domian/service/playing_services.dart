import 'package:injectable/injectable.dart';

import '../entity/recorded_audio_data.dart';
import '../repository/playing_repository.dart';

@lazySingleton
class PlayingServices {
  final PlayingRepository _playingRepository;

  const PlayingServices(this._playingRepository);

  Future<void> playAudio(RecordedAudioData data) => _playingRepository.playAudio(data);
}
