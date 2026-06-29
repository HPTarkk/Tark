import 'package:equatable/equatable.dart';

sealed class Failure extends Equatable {
  const Failure();
  @override
  List<Object?> get props => [];
}

class DataTransferFailure extends Failure {
  const DataTransferFailure();
}
