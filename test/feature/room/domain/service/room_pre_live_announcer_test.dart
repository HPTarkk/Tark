import 'dart:async';

import 'package:dartz/dartz.dart';
import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tark/core/error/failure.dart';
import 'package:tark/feature/room/domain/entity/room.dart';
import 'package:tark/feature/room/domain/service/room_pre_live_announcer.dart';
import 'package:tark/feature/transfer/domain/entity/transfer_mode.dart';
import 'package:tark/feature/transfer/domain/entity/waki_packet.dart';
import 'package:tark/feature/transfer/domain/repository/transfer_repository.dart';

void main() {
  group('RoomPreLiveAnnouncer', () {
    test('binds the socket and announces at once and periodically', () {
      fakeAsync((async) {
        final transport = _RecordingTransport();
        final announcer = RoomPreLiveAnnouncer(
          transport: transport,
          name: 'Rider one',
          interval: const Duration(seconds: 1),
        )..start();

        expect(transport.listens, 1);
        expect(transport.presences, ['Rider one']);

        async.elapse(const Duration(milliseconds: 3100));
        expect(transport.presences.length, 4);

        // Idempotent: a second start neither re-binds nor doubles presence.
        announcer.start();
        expect(transport.listens, 1);

        announcer.stop();
      });
    });

    test('hand-off stops announcing but leaves the socket to the live '
        'session', () {
      fakeAsync((async) {
        final transport = _RecordingTransport();
        final announcer = RoomPreLiveAnnouncer(transport: transport, name: '')
          ..start();

        announcer.handOff();
        final sent = transport.presences.length;
        async.elapse(const Duration(seconds: 5));

        expect(transport.presences.length, sent);
        expect(transport.stops, 0);

        // A later stop (the entry being disposed after going live) must not
        // tear down the socket the live session now owns.
        announcer.stop();
        expect(transport.stops, 0);
      });
    });

    test('stop releases the socket once and ends presence', () {
      fakeAsync((async) {
        final transport = _RecordingTransport();
        final announcer = RoomPreLiveAnnouncer(
          transport: transport,
          name: 'Rider one',
        )..start();

        announcer.stop();
        announcer.stop();
        final sent = transport.presences.length;
        async.elapse(const Duration(seconds: 5));

        expect(transport.stops, 1);
        expect(transport.presences.length, sent);
      });
    });

    test('stop before start touches nothing', () {
      final transport = _RecordingTransport();
      RoomPreLiveAnnouncer(transport: transport, name: '').stop();
      expect(transport.listens, 0);
      expect(transport.stops, 0);
    });

    test('applies only to the IP transports', () {
      expect(RoomPreLiveAnnouncer.appliesTo(TransferMode.wifi), isTrue);
      expect(RoomPreLiveAnnouncer.appliesTo(TransferMode.hotspot), isTrue);
      expect(RoomPreLiveAnnouncer.appliesTo(TransferMode.bluetooth), isFalse);
      expect(RoomPreLiveAnnouncer.appliesTo(TransferMode.guest), isFalse);
    });
  });

  group('RoomPreLiveAnnouncer.channelFor', () {
    const a = RoomId('0123456789abcdef0123456789abcdef');
    const b = RoomId('fedcba9876543210fedcba9876543210');

    test('every member of one Room derives the same closed channel', () {
      final first = RoomPreLiveAnnouncer.channelFor(a);
      final second = RoomPreLiveAnnouncer.channelFor(
        const RoomId('0123456789abcdef0123456789abcdef'),
      );
      expect(first.value, second.value);
      expect(first.isOpen, isFalse);
      expect(first.code, hasLength(6));
    });

    test('different Rooms get different channels', () {
      expect(
        RoomPreLiveAnnouncer.channelFor(a).value,
        isNot(RoomPreLiveAnnouncer.channelFor(b).value),
      );
    });
  });
}

class _RecordingTransport implements TransferRepository {
  int listens = 0;
  int stops = 0;
  final presences = <String>[];
  final _packets = StreamController<WakiPacket>.broadcast();

  @override
  Stream<WakiPacket> startListening() {
    listens++;
    return _packets.stream;
  }

  @override
  Future<Either<Failure, void>> sendPresence(
    String senderName,
    bool isTalking, {
    bool isLeaving = false,
  }) async {
    presences.add(senderName);
    return const Right(null);
  }

  @override
  void stopConnection() => stops++;

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError(invocation.memberName.toString());
}
