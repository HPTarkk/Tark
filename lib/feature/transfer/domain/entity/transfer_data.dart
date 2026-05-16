import 'package:equatable/equatable.dart';

import '../../../recording/domian/entity/recorded_audio_data.dart';

class TransferData extends Equatable {
  final RecordedAudioData data;
  const TransferData({required this.data});
  @override
  List<Object?> get props => [data];
}
