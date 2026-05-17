import 'package:dartz/dartz.dart';

import '../../../../core/error/failure.dart';
import '../entity/recorded_audio_data.dart';

abstract interface class RecordingRepository {
  Stream<Either<Failure, RecordedAudioData>> startRecording();

  Future<void> stopRecording();
}
