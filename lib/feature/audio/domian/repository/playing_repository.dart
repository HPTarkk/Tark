import '../entity/recorded_audio_data.dart';

abstract interface class PlayingRepository {

  Future<void> playAudio(RecordedAudioData data);
}
