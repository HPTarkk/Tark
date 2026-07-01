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

  // Every packet is sent to ALL of these. A device can sit on several IPv4
  // networks at once (hotspot AP interface + cellular, or WiFi + hotspot),
  // and only one of them contains the peers. Broadcasting on every interface
  // (plus the limited broadcast) means we never depend on interface order —
  // picking "the first non-loopback interface" broke the hotspot-host case,
  // where cellular is usually listed first.
  List<InternetAddress> _broadcastTargets = const [];
  DateTime _targetsResolvedAt = DateTime.fromMillisecondsSinceEpoch(0);
  static const _targetsMaxAge = Duration(seconds: 10);

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
      _sendToAllTargets(packet);
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
      _sendToAllTargets(packet);
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

      // Retry delay, sliced short: async* cancellation only takes effect
      // between awaits, so one long sleep here would make cancel() (and the
      // page teardown awaiting it) lag by whole seconds.
      for (var i = 0; i < 12 && _generation == myGen; i++) {
        await Future.delayed(const Duration(milliseconds: 250));
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
    // with correctly resolved broadcast targets (WiFi/network may change).
    _sendSocket?.close();
    _sendSocket = null;
    _broadcastTargets = const [];

    _addConnectionEvent(false);
  }

  Future<void> _ensureSendSocket() async {
    if (_sendSocket == null) {
      _sendSocket = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0);
      _sendSocket!.broadcastEnabled = true;
    }

    // Re-resolve periodically so a hotspot/WiFi interface that appears
    // mid-session (e.g. a client joining the hotspot brings the AP interface
    // up) starts receiving without needing to leave and rejoin the channel.
    final now = DateTime.now();
    if (_broadcastTargets.isEmpty ||
        now.difference(_targetsResolvedAt) > _targetsMaxAge) {
      _broadcastTargets = await _getBroadcastTargets();
      _targetsResolvedAt = now;
    }
  }

  void _sendToAllTargets(List<int> packet) {
    for (final target in _broadcastTargets) {
      _sendSocket!.send(packet, target, kBroadcastPort);
    }
  }

  /// Directed broadcast address (x.y.z.255) of every non-loopback IPv4
  /// interface, plus the limited broadcast 255.255.255.255.
  ///
  /// NetworkInterface.list doesn't expose the subnet prefix, so /24 is
  /// assumed — that matches Android/Windows/iPhone hotspots and virtually
  /// all home routers, and the limited broadcast covers the rest.
  Future<List<InternetAddress>> _getBroadcastTargets() async {
    final targets = <String>{'255.255.255.255'};
    try {
      final interfaces =
          await NetworkInterface.list(type: InternetAddressType.IPv4);
      for (final iface in interfaces) {
        for (final addr in iface.addresses) {
          if (addr.isLoopback) continue;
          final parts = addr.address.split('.');
          if (parts.length == 4) {
            targets.add('${parts[0]}.${parts[1]}.${parts[2]}.255');
          }
        }
      }
    } catch (e) {
      Logger.log('Could not enumerate broadcast addresses: $e');
    }
    Logger.log('Broadcast targets: $targets');
    return targets.map(InternetAddress.new).toList();
  }

  void _addConnectionEvent(bool isConnected) {
    if (_connectionController.isClosed) return;
    _connectionController.add(isConnected);
  }
}
