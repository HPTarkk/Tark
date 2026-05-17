import 'package:dartz/dartz.dart';
import 'package:injectable/injectable.dart';

import '../../../core/error/failure.dart';
import '../../audio/domian/entity/recorded_audio_data.dart';
import '../data/model/transfer_data_model.dart';
import '../domain/repository/transfer_repository.dart';

@lazySingleton
class TransferApi {
  final TransferRepository _transferRepository;

  const TransferApi(this._transferRepository);

  Future<Either<Failure, void>> sendData(RecordedAudioData data) =>
      _transferRepository.sendData(TransferDataModel.fromAudioSample(data));
}
