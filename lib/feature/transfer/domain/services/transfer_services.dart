import 'package:injectable/injectable.dart';

import '../entity/transfer_data.dart';
import '../repository/transfer_repository.dart';

@lazySingleton
class TransferServices {
  final TransferRepository _transferRepository;

  const TransferServices(this._transferRepository);

  Stream<TransferData> startListening() => _transferRepository.startListening();

  Stream<bool> connect() => _transferRepository.connect();
  
  void stopConnection() => _transferRepository.stopConnection();
}
