/// Public surface of the audio feature.
///
/// Everything outside lib/feature/audio must import this barrel (or core/)
/// — never the feature's internal domain/data/presentation files.
library;

export '../data/media_control.dart' show MediaControl;
export '../data/session_keep_alive.dart' show SessionKeepAlive;
export '../data/system_audio_capture.dart' show SystemAudioCapture;
export '../domain/entity/audio_engine_status.dart';
export '../domain/entity/audio_frame.dart';
export '../domain/service/audio_engine.dart';
export '../presentation/widget/audio_visualizer.dart';
