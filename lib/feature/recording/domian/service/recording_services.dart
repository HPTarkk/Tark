import 'package:dartz/dartz.dart';
import 'package:injectable/injectable.dart';

import '../../../../core/error/failure.dart';
import '../entity/recorded_audio_data.dart';
import '../repository/recording_repository.dart';

@lazySingleton
class RecordingServices {
  final RecordingRepository _recordingRepository;

  const RecordingServices(this._recordingRepository);

  Stream<Either<Failure, RecordedAudioData>> startRecording() => _recordingRepository.startRecording();

  Future<void> stopRecording() => _recordingRepository.stopRecording();
}
