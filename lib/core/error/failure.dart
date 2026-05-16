import 'package:equatable/equatable.dart';

sealed class Failure extends Equatable {
  const Failure();
  @override
  List<Object?> get props => [];
}

class AudioRecordingFailure extends Failure {
  const AudioRecordingFailure();
}

class PermissionAudioRecordingFailure extends Failure {
  const PermissionAudioRecordingFailure();
}


class AudioSpeackerFailure extends Failure {
  const AudioSpeackerFailure();
}
