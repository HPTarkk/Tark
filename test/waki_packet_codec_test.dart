import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:tark/feature/transfer/data/codec/waki_packet_codec.dart';
import 'package:tark/feature/transfer/domain/entity/session_role.dart';
import 'package:tark/feature/transfer/domain/entity/waki_packet.dart';

/// Builds a v1 packet — the pre-device-id format, which nothing emits any more
/// but every decoder still has to understand.
Uint8List v1Presence(String name, {required bool isTalking}) {
  final nameBytes = utf8.encode(name);
  final builder = BytesBuilder(copy: false);
  builder.addByte(kPresenceByte);
  builder.add(
    (ByteData(
      4,
    )..setUint32(0, nameBytes.length, Endian.little)).buffer.asUint8List(),
  );
  builder.add(nameBytes);
  builder.addByte(isTalking ? 0x01 : 0x00);
  return builder.toBytes();
}

void main() {
  late WakiPacketCodec codec;

  setUp(() => codec = WakiPacketCodec('abc123abc123'));
  tearDown(() => codec.release());

  group('v2 round trip', () {
    test('presence carries the sender device id, not the transport id', () {
      final packet = codec.decode(
        codec.encodePresence('Pedram', true, role: SessionRole.host),
        '192.168.43.7',
      );

      expect(packet, isA<PresencePacket>());
      // The whole point: identity comes off the wire, so it is the same value
      // whichever address the datagram arrived from.
      expect(packet!.senderId, 'abc123abc123');
      expect(packet.senderName, 'Pedram');
      expect((packet as PresencePacket).isTalking, isTrue);
      expect(packet.role, SessionRole.host);
    });

    test('every role survives the wire', () {
      for (final role in SessionRole.values) {
        final packet = codec.decode(
          codec.encodePresence('Pedram', false, role: role),
          '192.168.43.7',
        );
        expect((packet! as PresencePacket).role, role, reason: '$role');
      }
    });

    group('the heard list', () {
      PresencePacket roundTrip({List<String>? heardIds}) =>
          codec.decode(
                codec.encodePresence(
                  'Pedram',
                  false,
                  role: SessionRole.peer,
                  heardIds: heardIds,
                ),
                '192.168.43.7',
              )!
              as PresencePacket;

      test('carries the ids the sender says it can hear', () {
        expect(
          roundTrip(heardIds: ['aaa111aaa111', 'bbb222bbb222']).heardIds,
          ['aaa111aaa111', 'bbb222bbb222'],
        );
      });

      test('an explicit empty list survives as an empty list', () {
        // The whole point of the field: "I can hear nobody" has to reach the
        // other end intact, because that is the sentence a phone whose send
        // path has died needs to receive.
        expect(roundTrip(heardIds: const []).heardIds, isEmpty);
      });

      test('saying nothing is null, not an empty list', () {
        // Point-to-point transports and older builds both land here, and
        // neither is claiming to hear nobody.
        expect(roundTrip().heardIds, isNull);
      });

      test('a packet from a build that predates the field reads as null', () {
        // Exactly what an older sender emits: header, isTalking, role, end.
        final legacy = codec.encodePresence(
          'Old build',
          false,
          role: SessionRole.host,
        );
        expect(
          (codec.decode(legacy, '1.2.3.4')! as PresencePacket).heardIds,
          isNull,
        );
      });

      test('a truncated list is no opinion rather than a short one', () {
        final full = codec.encodePresence(
          'Pedram',
          false,
          role: SessionRole.peer,
          heardIds: const ['aaa111aaa111', 'bbb222bbb222'],
        );
        // Chop the tail, as a clipped datagram would. Reading half a list and
        // concluding "my id is missing" is how a healthy link gets torn down.
        final clipped = Uint8List.sublistView(full, 0, full.length - 9);
        expect(
          (codec.decode(clipped, '1.2.3.4')! as PresencePacket).heardIds,
          isNull,
        );
      });

      test('the list is capped so presence stays inside one datagram', () {
        final many = List.generate(40, (i) => 'id${i.toString().padLeft(10, '0')}');
        final decoded = roundTrip(heardIds: many).heardIds!;
        expect(decoded.length, lessThanOrEqualTo(12));
        expect(decoded.first, many.first);
      });

      test('a peer on an older build still decodes our packet', () {
        // Trailing bytes, so the fields an old decoder knows about are all
        // still where it expects them.
        final withList = codec.encodePresence(
          'Pedram',
          true,
          role: SessionRole.host,
          heardIds: const ['aaa111aaa111'],
        );
        final packet = codec.decode(withList, '1.2.3.4')! as PresencePacket;
        expect(packet.senderName, 'Pedram');
        expect(packet.isTalking, isTrue);
        expect(packet.role, SessionRole.host);
      });
    });

    test('a role this build has never heard of reads as unknown', () {
      final packet = codec.encodePresence(
        'Future',
        false,
        role: SessionRole.host,
      );
      // Last byte is the role — a later build may put anything there.
      packet[packet.length - 1] = 99;

      final decoded = codec.decode(packet, '192.168.43.7');
      expect(decoded, isNotNull, reason: 'the packet is still perfectly good');
      expect((decoded! as PresencePacket).role, SessionRole.unknown);
    });

    test('audio carries the device id and survives the seq', () {
      final samples = List<double>.generate(160, (i) => (i % 32) / 64);
      final packet = codec.decode(
        codec.encodeAudio(samples, 'Pedram', 4242),
        '10.0.0.9',
      );

      expect(packet, isA<AudioPacket>());
      expect(packet!.senderId, 'abc123abc123');
      final audio = packet as AudioPacket;
      expect(audio.seq, 4242);
      expect(audio.samples, hasLength(samples.length));
    });

    test('two codecs on one host stay distinguishable', () {
      final other = WakiPacketCodec('ffffffffffff');
      addTearDown(other.release);

      final mine = codec.decode(
        codec.encodePresence('A', false, role: SessionRole.peer),
        '1.2.3.4',
      );
      final theirs = other.decode(
        other.encodePresence('B', false, role: SessionRole.peer),
        '1.2.3.4',
      );

      // Same source address, different devices — the case that used to
      // collapse two phones into one roster entry.
      expect(mine!.senderId, isNot(theirs!.senderId));
    });

    test('a name with multi-byte characters survives the id prefix', () {
      final packet = codec.decode(
        codec.encodePresence('پدرام', false, role: SessionRole.joiner),
        '192.168.43.7',
      );

      expect(packet!.senderName, 'پدرام');
      expect(packet.senderId, 'abc123abc123');
    });
  });

  group('v1 compatibility', () {
    test('presence still decodes, falling back to the transport id', () {
      final packet = codec.decode(
        v1Presence('Legacy', isTalking: true),
        '192.168.43.7',
      );

      expect(packet, isA<PresencePacket>());
      expect(packet!.senderId, '192.168.43.7');
      expect(packet.senderName, 'Legacy');
      expect((packet as PresencePacket).isTalking, isTrue);
      expect(packet.role, SessionRole.unknown);
    });
  });

  group('pre-role compatibility', () {
    test('a v2 presence without the role byte still decodes', () {
      // Byte-for-byte what a build from before roles puts on the wire: the
      // v2 header, isTalking, and nothing after it.
      final withRole = codec.encodePresence(
        'Older',
        true,
        role: SessionRole.host,
      );
      final withoutRole = Uint8List.sublistView(
        withRole,
        0,
        withRole.length - 1,
      );

      final packet = codec.decode(withoutRole, '192.168.43.7');
      expect(packet, isA<PresencePacket>());
      expect(packet!.senderName, 'Older');
      expect((packet as PresencePacket).isTalking, isTrue);
      expect(packet.role, SessionRole.unknown);
    });
  });

  group('malformed input', () {
    test('empty and truncated buffers are rejected, not thrown on', () {
      expect(codec.decode(Uint8List(0), 'x'), isNull);
      expect(codec.decode(Uint8List.fromList([kPresenceV2Byte]), 'x'), isNull);
      // Claims a 200-byte device id it does not have.
      expect(
        codec.decode(Uint8List.fromList([kPresenceV2Byte, 200, 0x61]), 'x'),
        isNull,
      );
    });

    test('a truncated v2 packet is rejected at every prefix length', () {
      final full = codec.encodePresence('Pedram', true, role: SessionRole.host);
      // Stops one short of the role byte: that prefix is not truncation but
      // the pre-role format, and it decodes on purpose (covered above).
      for (var length = 1; length < full.length - 1; length++) {
        expect(
          codec.decode(Uint8List.sublistView(full, 0, length), 'x'),
          isNull,
          reason: 'prefix of length $length should not decode',
        );
      }
      expect(codec.decode(full, 'x'), isNotNull);
    });

    test('an unknown type byte is dropped', () {
      expect(codec.decode(Uint8List.fromList([0x7f, 0, 0, 0, 0, 0]), 'x'),
          isNull);
    });
  });
}
