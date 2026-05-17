import 'package:audio_io/audio_io.dart';
import 'package:dartz/dartz.dart';
import 'package:injectable/injectable.dart';
import 'package:permission_handler/permission_handler.dart';

import '../../../../core/error/failure.dart';
import '../../domian/entity/recorded_audio_data.dart';
import '../../domian/repository/recording_repository.dart';
import '../model/recorded_audio_data_model.dart';

@LazySingleton(as: RecordingRepository)
class RecordingRepositoryImpl implements RecordingRepository {
  final AudioIo _audioIo;
  const RecordingRepositoryImpl(this._audioIo);

  @override
  Stream<Either<Failure, RecordedAudioData>> startRecording() async* {
    try {
      final status = await Permission.microphone.request();
      if (status.isGranted) {
        await _audioIo.stop();
        await _audioIo.requestLatency(AudioIoLatency.Balanced);
        await _audioIo.start();
        yield* _audioIo.input.map((event) => Right(RecordedAudioDataModel.fromSample(event)));
      } else {
        yield const Left(PermissionAudioRecordingFailure());
      }
    } on AudioIoException catch (e) {
      if (e.isPermissionDenied) {
        yield const Left(PermissionAudioRecordingFailure());
        return;
      }
      yield const Left(AudioRecordingFailure());
    }
  }

  @override
  Future<void> stopRecording() async {
    await _audioIo.stop();
  }
}
