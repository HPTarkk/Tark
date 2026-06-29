import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dartz/dartz.dart';
import 'package:injectable/injectable.dart';

import '../../../../core/error/failure.dart';
import '../../../../core/utils/logger.dart';
import '../../../walkie/domain/entity/waki_packet.dart';
import '../../domain/repository/transfer_repository.dart';

const kBroadcastPort = 4000;
const _kPresenceByte = 0x01;
const _kAudioByte = 0x02;

@LazySingleton(as: TransferRepository)
class TransferRepositoryImpl implements TransferRepository {
  RawDatagramSocket? _sendSocket;
  RawDatagramSocket? _receiveSocket;
  final _connectionController = StreamController<bool>.broadcast();
  String? _broadcastAddress;

  // Incremented each time startListening() is called so any in-flight
  // generator from a previous session knows to stop when it wakes from
  // its retry delay and sees a different generation number.
  int _generation = 0;

  TransferRepositoryImpl();

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
      final packet = _buildAudioPacket(samples, senderName);
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
      final packet = _buildPresencePacket(senderName, isTalking);
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
              final packet = _parsePacket(dg!.data, dg.address.address);
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

  WakiPacket? _parsePacket(Uint8List bytes, String senderIp) {
    if (bytes.length < 6) return null;
    final type = bytes[0];
    final bd = ByteData.sublistView(bytes);
    final nameLen = bd.getUint32(1, Endian.little);
    if (bytes.length < 5 + nameLen) return null;

    final name =
        utf8.decode(bytes.sublist(5, 5 + nameLen), allowMalformed: true);

    if (type == _kPresenceByte) {
      if (bytes.length < 5 + nameLen + 1) return null;
      final isTalking = bytes[5 + nameLen] == 0x01;
      return PresencePacket(
          senderIp: senderIp, senderName: name, isTalking: isTalking);
    } else if (type == _kAudioByte) {
      final audioBytes = bytes.sublist(5 + nameLen);
      if (audioBytes.isEmpty) return null;
      final samples = _bytesToSamples(audioBytes);
      return AudioPacket(
          senderIp: senderIp, senderName: name, samples: samples);
    }
    return null;
  }

  Uint8List _buildAudioPacket(List<double> samples, String senderName) {
    final nameBytes = utf8.encode(senderName);
    final audioData = ByteData(samples.length * 4);
    for (int i = 0; i < samples.length; i++) {
      audioData.setFloat32(i * 4, samples[i].clamp(-1.0, 1.0), Endian.little);
    }
    final builder = BytesBuilder(copy: false);
    builder.addByte(_kAudioByte);
    builder.add((ByteData(4)
          ..setUint32(0, nameBytes.length, Endian.little))
        .buffer
        .asUint8List());
    builder.add(nameBytes);
    builder.add(audioData.buffer.asUint8List());
    return builder.toBytes();
  }

  Uint8List _buildPresencePacket(String senderName, bool isTalking) {
    final nameBytes = utf8.encode(senderName);
    final builder = BytesBuilder(copy: false);
    builder.addByte(_kPresenceByte);
    builder.add((ByteData(4)
          ..setUint32(0, nameBytes.length, Endian.little))
        .buffer
        .asUint8List());
    builder.add(nameBytes);
    builder.addByte(isTalking ? 0x01 : 0x00);
    return builder.toBytes();
  }

  List<double> _bytesToSamples(Uint8List bytes) {
    final bd = ByteData.sublistView(bytes);
    final count = bytes.length ~/ 4;
    return List.generate(count, (i) => bd.getFloat32(i * 4, Endian.little));
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
