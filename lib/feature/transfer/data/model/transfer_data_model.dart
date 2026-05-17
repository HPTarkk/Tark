import 'dart:typed_data';

import '../../../audio/data/model/recorded_audio_data_model.dart';
import '../../../audio/domian/entity/recorded_audio_data.dart';
import '../../domain/entity/transfer_data.dart';

class TransferDataModel extends TransferData {
  const TransferDataModel({required super.data});

  factory TransferDataModel.fromSuper(TransferData entity) => TransferDataModel(data: entity.data);

  factory TransferDataModel.fromAudioSample(RecordedAudioData data) => TransferDataModel(data: data);

  factory TransferDataModel.fromBytes(Uint8List bytes) {
    final byteData = ByteData.sublistView(bytes);
    final sampleCount = bytes.length ~/ 4;
    final samples = List<double>.filled(sampleCount, 0);
    for (int i = 0; i < sampleCount; i++) {
      samples[i] = byteData.getFloat32(i * 4, Endian.little);
    }
    return TransferDataModel(data: RecordedAudioDataModel.fromSample(samples));
  }

  Uint8List get message {
    final byteData = ByteData(data.sampleData.length * 4);
    for (int i = 0; i < data.sampleData.length; i++) {
      byteData.setFloat32(i * 4, data.sampleData[i], Endian.little);
    }
    return byteData.buffer.asUint8List();
  }
}
