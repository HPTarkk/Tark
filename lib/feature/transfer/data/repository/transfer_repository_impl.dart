import 'package:dartz/dartz.dart';
import 'package:injectable/injectable.dart';

import '../../../../core/error/failure.dart';
import '../../domain/entity/transfer_data.dart';
import '../../domain/repository/transfer_repository.dart';

@LazySingleton(as: TransferRepository)
class TransferRepositoryImpl implements TransferRepository {
  @override
  Future<Either<Failure, void>> sendData(TransferData data) {
    // TODO: implement sendData
    throw UnimplementedError();
  }

  @override
  Stream<TransferData> startListening() {
    // TODO: implement startListening
    throw UnimplementedError();
  }
  
  @override
  Future<void> stopListening() {
    // TODO: implement stopListening
    throw UnimplementedError();
  }
}
