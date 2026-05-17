import '../../domian/entity/recorded_audio_data.dart';

class RecordedAudioDataModel extends RecordedAudioData {
  RecordedAudioDataModel(super.sampleData);

  factory RecordedAudioDataModel.fromSample(List<double> sampleData) => RecordedAudioDataModel(sampleData);
}
