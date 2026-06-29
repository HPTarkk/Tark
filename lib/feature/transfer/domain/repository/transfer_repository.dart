import 'package:dartz/dartz.dart';

import '../../../../core/error/failure.dart';
import '../../../walkie/domain/entity/waki_packet.dart';

abstract interface class TransferRepository {
  Stream<WakiPacket> startListening();

  Future<Either<Failure, void>> sendAudio(List<double> samples, String senderName);

  Future<Either<Failure, void>> sendPresence(String senderName, bool isTalking);

  Stream<bool> connect();

  void stopConnection();

  void dispose();
}
