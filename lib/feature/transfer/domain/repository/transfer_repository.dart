import 'package:dartz/dartz.dart';

import '../../../../core/error/failure.dart';
import '../entity/transfer_data.dart';

abstract interface class TransferRepository {
  Stream<TransferData> startListening();

  Future<Either<Failure, void>> sendData(TransferData data);

  Stream<bool> connect();

  void stopConnection();

  void dispose();
}
