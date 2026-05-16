import 'package:equatable/equatable.dart';
import 'package:flutter/cupertino.dart';
import 'package:wakitaki/core/l10n/extension.dart';

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

extension FailureMessageExt on Failure {
  String getMessage(BuildContext context) {
    return switch (this) {
      AudioRecordingFailure() => context.getString.audio_recording_general_error_message,
      PermissionAudioRecordingFailure() => context.getString.audio_recording_permission_error_message,
    };
  }
}
