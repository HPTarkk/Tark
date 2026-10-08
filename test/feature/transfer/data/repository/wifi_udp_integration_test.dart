import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:tark/core/identity/channel_id.dart';
import 'package:tark/core/identity/channel_membership.dart';
import 'package:tark/core/identity/device_identity.dart';
import 'package:tark/core/identity/session_epoch.dart';
import 'package:tark/feature/transfer/data/codec/waki_packet_codec.dart';
import 'package:tark/feature/transfer/data/repository/wifi_transfer_repository_impl.dart';
import 'package:tark/feature/transfer/domain/entity/connection_health.dart';
import 'package:tark/feature/transfer/domain/entity/session_role.dart';
import 'package:tark/feature/transfer/domain/entity/waki_packet.dart';
import 'package:tark/feature/transfer/domain/service/session_role_store.dart';

class _Role implements SessionRoleStore {
  @override
  SessionRole? role;
  @override
  void setRole(SessionRole value) => role = value;
  @override
  void clear() => role = null;
}

// Real UDP loopback through the production receive pipeline: malformed input
// cannot tear down a live socket, and channel/epoch gates precede peer state.
void main() {
  test(
    'UDP framing, channel isolation and rebind keep one logical session',
    () async {
      final membership = ChannelMembership()..join(const ChannelId(123));
      final epoch = SessionEpoch();
      final repository = WifiTransferRepositoryImpl(
        const DeviceIdentity.withId('local-device'),
        epoch,
        _Role(),
        membership,
      );
      final peerMembership = ChannelMembership()..join(const ChannelId(123));
      final peerEpoch = SessionEpoch.startingAt(3);
      final peer = WakiPacketCodec('remote-device', peerEpoch, peerMembership);
      final socket = await RawDatagramSocket.bind(
        InternetAddress.loopbackIPv4,
        0,
      );
      final packets = <WakiPacket>[];
      final packetEvents = StreamController<WakiPacket>.broadcast();
      final health = <ConnectionHealth>[];
      final healthEvents = StreamController<ConnectionHealth>.broadcast();
      final healthSub = repository.connect().listen((event) {
        health.add(event);
        healthEvents.add(event);
      });
      final listening = repository.startListening().listen((packet) {
        packets.add(packet);
        packetEvents.add(packet);
      });
      addTearDown(() async {
        repository.stopConnection();
        await listening.cancel();
        await healthSub.cancel();
        repository.dispose();
        peer.release();
        socket.close();
        await packetEvents.close();
        await healthEvents.close();
      });
      Future<void> waitHealthy() async {
        if (repository.currentConnectionHealth?.isHealthy == true) return;
        await healthEvents.stream
            .firstWhere((event) => event.isHealthy)
            .timeout(const Duration(seconds: 5));
      }

      void send(Uint8List bytes) =>
          socket.send(bytes, InternetAddress.loopbackIPv4, kBroadcastPort);
      Future<WakiPacket> sendAudio(int sequence) async {
        final next = packetEvents.stream.first.timeout(
          const Duration(seconds: 5),
        );
        send(peer.encodeAudio(List<double>.filled(320, 0.2), 'Peer', sequence));
        return next;
      }

      await waitHealthy();
      final initialEpoch = epoch.value;
      send(Uint8List(0));
      send(Uint8List.fromList([0xff]));
      send(Uint8List.fromList([kAudioV4Byte]));
      peerMembership.join(const ChannelId(999));
      send(peer.encodeAudio(List<double>.filled(320, 0.2), 'Other room', 1));
      peerMembership.join(const ChannelId(123));
      final first = await sendAudio(2);
      expect(first, isA<AudioPacket>());
      expect((first as AudioPacket).seq, 2);
      expect(first.samples, hasLength(320));
      expect(first.samples.first, closeTo(0.2, 1 / 32768));
      expect(packets, hasLength(1));
      expect(repository.stats.peerCount, 1);
      expect(
        health.every((event) => event.isHealthy),
        isTrue,
        reason: 'malformed datagrams must not tear down the socket',
      );

      // Once a later join has been observed, delayed audio from the old join
      // must neither reach playout nor refresh the peer's logical session.
      peerEpoch.renew();
      await sendAudio(3);
      final stale = WakiPacketCodec(
        'remote-device',
        SessionEpoch.startingAt(3),
        peerMembership,
      );
      send(stale.encodeAudio(List<double>.filled(320, 0.3), 'Peer', 4));
      stale.release();
      await sendAudio(5);
      expect(packets.whereType<AudioPacket>().map((packet) => packet.seq), [
        2,
        3,
        5,
      ]);
      expect(repository.stats.staleEpochDrops, 1);

      final rebound = healthEvents.stream
          .firstWhere((event) => event.isHealthy)
          .timeout(const Duration(seconds: 5));
      repository.rebindSockets();
      await rebound;
      await sendAudio(6);
      expect(
        epoch.value,
        initialEpoch,
        reason: 'socket rebind must preserve the session epoch',
      );
      expect(packets.last, isA<AudioPacket>());
    },
  );
}
