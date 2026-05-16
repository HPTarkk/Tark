import 'package:dartz/dartz.dart';

import '../../../../core/error/failure.dart';
import '../entity/transfer_data.dart';

abstract interface class TransferRepository {
  Stream<TransferData> startListening();

  Future<void> stopListening();

  Future<Either<Failure, void>> sendData(TransferData data);
}
