import 'dart:math';

import 'package:equatable/equatable.dart';

class RecordedAudioData extends Equatable {
  final List<double> sampleData;
  final double rms;
  RecordedAudioData(this.sampleData) : rms = calculateRMS(sampleData);

  @override
  List<Object?> get props => [sampleData, rms];

  static double calculateRMS(List<double> sampleData) =>
      sqrt(sampleData.fold<double>(0.0, (sum, sample) => sum + sample * sample) / sampleData.length);
}
