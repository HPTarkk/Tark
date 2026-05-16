import 'package:dartz/dartz.dart';
import 'package:wakitaki/core/error/failure.dart';
import 'package:wakitaki/feature/transfer/domain/entity/transfer_data.dart';

abstract interface class TransferRepository {
  Future<Either<Failure, void>> sendData(TransferData data);
}
