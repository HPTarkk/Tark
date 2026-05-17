import 'dart:async';
import 'dart:io';

import 'package:dartz/dartz.dart';
import 'package:injectable/injectable.dart';

import '../../../../core/error/failure.dart';
import '../../../../core/utils/logger.dart';
import '../../domain/entity/transfer_data.dart';
import '../../domain/repository/transfer_repository.dart';
import '../model/transfer_data_model.dart';

const kBraodcastPort = 4000;

@LazySingleton(as: TransferRepository)
class TransferRepositoryImpl implements TransferRepository {
  RawDatagramSocket? _sendSocket;
  RawDatagramSocket? _recieveSocket;
  final _connectionController = StreamController<bool>();

  TransferRepositoryImpl();

  @disposeMethod
  @override
  void dispose() {
    _sendSocket?.close();
    _recieveSocket?.close();
    _connectionController.close();
  }

  @override
  Future<Either<Failure, void>> sendData(TransferData data) async {
    try {
      _sendSocket ??= await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0);
      Logger.log('Broadcast sender socket ready on port ${_sendSocket!.port}');
      InternetAddress broadcastAddress = InternetAddress('192.168.1.255');
      _sendSocket!.send(TransferDataModel.fromSuper(data).message, broadcastAddress, kBraodcastPort);
      Logger.log('Broadcast audio sent to $broadcastAddress:$kBraodcastPort');
      return Right(null);
    } catch (error) {
      Logger.log(error);
      return Left(DataTransferFailure());
    }
  }

  @override
  Stream<TransferData> startListening() async* {
    try {
      _recieveSocket ??= await RawDatagramSocket.bind(InternetAddress.anyIPv4, kBraodcastPort);
      _addConnectionEvent(true);
      Logger.log('Listening for broadcasts on port ${_recieveSocket!.port}');
      yield* _recieveSocket!
          .where((event) => event == RawSocketEvent.read)
          .transform(
            StreamTransformer.fromHandlers(
              handleData: (data, sink) {
                // (event) {
                final datagram = _recieveSocket?.receive();
                if (datagram != null) {
                  Logger.log('Data received with size ${datagram.data.lengthInBytes}');
                  sink.add(TransferDataModel.fromBytes(datagram.data));
                }
              },
              handleError: (error, stackTrace, sink) {
                Logger.log(error);
                _addConnectionEvent(false);
                sink.close();
              },
            ),
          );
    } catch (error) {
      _addConnectionEvent(false);
      Logger.log(error);
    }
  }

  void _addConnectionEvent(bool isConnected) {
    if (_connectionController.isClosed) return;
    _connectionController.add(isConnected);
  }

  @override
  void stopConnection() {
    _recieveSocket?.close();
    _addConnectionEvent(false);
  }

  @override
  Stream<bool> connect() => _connectionController.stream.asBroadcastStream();
}
