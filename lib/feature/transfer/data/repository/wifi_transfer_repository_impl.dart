import 'dart:async';
import 'dart:io';

import 'package:dartz/dartz.dart';
import 'package:injectable/injectable.dart';

import '../../../../core/error/failure.dart';
import '../../../../core/utils/logger.dart';
import '../../../walkie/domain/entity/waki_packet.dart';
import '../../domain/repository/transfer_repository.dart';
import '../codec/waki_packet_codec.dart';

const kBroadcastPort = 4000;

@LazySingleton()
class WifiTransferRepositoryImpl implements TransferRepository {
  RawDatagramSocket? _sendSocket;
  RawDatagramSocket? _receiveSocket;
  final _connectionController = StreamController<bool>.broadcast();
  String? _broadcastAddress;
  final _codec = const WakiPacketCodec();

  // Incremented each time startListening() is called so any in-flight
  // generator from a previous session knows to stop when it wakes from
  // its retry delay and sees a different generation number.
  int _generation = 0;

  // Per-outgoing-stream counter so receivers can detect UDP loss/reordering.
  int _audioSeq = 0;

  WifiTransferRepositoryImpl();

  @disposeMethod
  @override
  void dispose() {
    _generation++;
    _sendSocket?.close();
    _sendSocket = null;
    _receiveSocket?.close();
    _receiveSocket = null;
    _connectionController.close();
  }

  @override
  Future<Either<Failure, void>> sendAudio(
      List<double> samples, String senderName) async {
    try {
      await _ensureSendSocket();
      final packet = _codec.encodeAudio(samples, senderName, _audioSeq++);
      _sendSocket!.send(
          packet, InternetAddress(_broadcastAddress!), kBroadcastPort);
      return const Right(null);
    } catch (error) {
      Logger.log(error);
      return const Left(DataTransferFailure());
    }
  }

  @override
  Future<Either<Failure, void>> sendPresence(
      String senderName, bool isTalking) async {
    try {
      await _ensureSendSocket();
      final packet = _codec.encodePresence(senderName, isTalking);
      _sendSocket!.send(
          packet, InternetAddress(_broadcastAddress!), kBroadcastPort);
      return const Right(null);
    } catch (error) {
      Logger.log(error);
      return const Left(DataTransferFailure());
    }
  }

  @override
  Stream<WakiPacket> startListening() async* {
    // Claim this generation slot. Any previous generator still alive in a
    // retry-delay sleep will see _generation != myGen and exit cleanly.
    final myGen = ++_generation;

    while (_generation == myGen) {
      try {
        _receiveSocket?.close();
        _receiveSocket = null;

        _receiveSocket = await RawDatagramSocket.bind(
          InternetAddress.anyIPv4,
          kBroadcastPort,
        );
        _receiveSocket!.broadcastEnabled = true;
        _addConnectionEvent(true);
        Logger.log('UDP socket bound on port $kBroadcastPort (gen $myGen)');

        await for (final event in _receiveSocket!) {
          if (_generation != myGen) break;
          if (event == RawSocketEvent.read) {
            Datagram? dg;
            while ((dg = _receiveSocket?.receive()) != null) {
              final packet = _codec.decode(dg!.data, dg.address.address);
              if (packet != null) yield packet;
            }
          } else if (event == RawSocketEvent.closed) {
            break;
          }
        }

        _addConnectionEvent(false);
      } catch (error) {
        Logger.log('Socket error (gen $myGen): $error');
        _addConnectionEvent(false);
        _receiveSocket?.close();
        _receiveSocket = null;
      }

      if (_generation == myGen) {
        await Future.delayed(const Duration(seconds: 3));
      }
    }
  }

  @override
  Stream<bool> connect() => _connectionController.stream;

  @override
  void stopConnection() {
    // Invalidate any running generator by advancing the generation counter.
    _generation++;

    _receiveSocket?.close();
    _receiveSocket = null;

    // Also tear down the send socket so the next session gets a fresh one
    // with a correctly resolved broadcast address (WiFi/network may change).
    _sendSocket?.close();
    _sendSocket = null;
    _broadcastAddress = null;

    _addConnectionEvent(false);
  }

  Future<void> _ensureSendSocket() async {
    if (_sendSocket != null) return;
    _broadcastAddress ??= await _getBroadcastAddress();
    _sendSocket = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0);
    _sendSocket!.broadcastEnabled = true;
    Logger.log(
        'Send socket ready, broadcasting to $_broadcastAddress:$kBroadcastPort');
  }

  Future<String> _getBroadcastAddress() async {
    try {
      final interfaces =
          await NetworkInterface.list(type: InternetAddressType.IPv4);
      for (final iface in interfaces) {
        for (final addr in iface.addresses) {
          if (!addr.isLoopback) {
            final parts = addr.address.split('.');
            if (parts.length == 4) {
              return '${parts[0]}.${parts[1]}.${parts[2]}.255';
            }
          }
        }
      }
    } catch (e) {
      Logger.log('Could not determine broadcast address: $e');
    }
    return '255.255.255.255';
  }

  void _addConnectionEvent(bool isConnected) {
    if (_connectionController.isClosed) return;
    _connectionController.add(isConnected);
  }
}
