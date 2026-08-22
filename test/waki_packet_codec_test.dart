import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:tark/core/identity/channel_id.dart';
import 'package:tark/core/identity/channel_membership.dart';
import 'package:tark/core/identity/session_epoch.dart';
import 'package:tark/feature/transfer/data/codec/waki_packet_codec.dart';
import 'package:tark/feature/transfer/domain/entity/control_packet.dart';
import 'package:tark/feature/transfer/domain/entity/session_role.dart';
import 'package:tark/feature/transfer/domain/entity/waki_packet.dart';
import 'package:tark/feature/transfer/domain/service/audio_capability_negotiator.dart';

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

/// Builds a v2 packet — the pre-epoch format, which nothing emits any more but
/// every decoder still has to understand.
Uint8List v2Presence(
  String deviceId,
  String name, {
  required bool isTalking,
  required SessionRole role,
}) {
  final idBytes = utf8.encode(deviceId);
  final nameBytes = utf8.encode(name);
  final builder = BytesBuilder(copy: false);
  builder.addByte(kPresenceV2Byte);
  builder.addByte(idBytes.length);
  builder.add(idBytes);
  builder.add(
    (ByteData(
      4,
    )..setUint32(0, nameBytes.length, Endian.little)).buffer.asUint8List(),
  );
  builder.add(nameBytes);
  builder.addByte(isTalking ? 0x01 : 0x00);
  builder.addByte(role.wireByte);
  return builder.toBytes();
}

/// Builds a v3 presence packet ending right after the role byte — exactly
/// what a build between roles shipping and the heard list (and, later, #28's
/// capability byte) emits. What "reads back as null/no opinion" is tested
/// against for both later fields.
Uint8List v3PresenceNoTrailer(
  String deviceId,
  String name,
  int epoch, {
  required bool isTalking,
  required SessionRole role,
}) {
  final idBytes = utf8.encode(deviceId);
  final nameBytes = utf8.encode(name);
  final builder = BytesBuilder(copy: false);
  builder.addByte(kPresenceV3Byte);
  builder.addByte(idBytes.length);
  builder.add(idBytes);
  builder.add(
    (ByteData(4)..setUint32(0, epoch, Endian.little)).buffer.asUint8List(),
  );
  builder.add(
    (ByteData(
      4,
    )..setUint32(0, nameBytes.length, Endian.little)).buffer.asUint8List(),
  );
  builder.add(nameBytes);
  builder.addByte(isTalking ? 0x01 : 0x00);
  builder.addByte(role.wireByte);
  return builder.toBytes();
}

/// Builds a v3 presence packet with an explicit capability byte.
///
/// [codec.encodePresence] can't produce a non-zero one today — its
/// capability byte tracks the real, still legacy-only
/// `AudioFormatProfile.supported` — so this is how the decode side gets
/// exercised against a value it will only see from a future HD-capable
/// build. [heardIds] null writes the no-opinion sentinel (`0xFF`, see
/// `WakiPacketCodec._kNoHeardIdsOpinion`) instead of omitting the section —
/// which is the whole fix this file is pinning down: a genuinely *omitted*
/// heardIds section would leave nothing to tell "this next byte is a heard-id
/// count" from "this next byte is the capability byte" apart.
Uint8List v3PresenceWithCapability(
  String deviceId,
  String name,
  int epoch, {
  required bool isTalking,
  required SessionRole role,
  List<String>? heardIds,
  required int capabilityBitmask,
}) {
  final idBytes = utf8.encode(deviceId);
  final nameBytes = utf8.encode(name);
  final builder = BytesBuilder(copy: false);
  builder.addByte(kPresenceV3Byte);
  builder.addByte(idBytes.length);
  builder.add(idBytes);
  builder.add(
    (ByteData(4)..setUint32(0, epoch, Endian.little)).buffer.asUint8List(),
  );
  builder.add(
    (ByteData(
      4,
    )..setUint32(0, nameBytes.length, Endian.little)).buffer.asUint8List(),
  );
  builder.add(nameBytes);
  builder.addByte(isTalking ? 0x01 : 0x00);
  builder.addByte(role.wireByte);
  if (heardIds == null) {
    builder.addByte(0xFF); // the no-opinion sentinel
  } else {
    builder.addByte(heardIds.length);
    for (final id in heardIds) {
      final idBytes2 = utf8.encode(id);
      builder.addByte(idBytes2.length);
      builder.add(idBytes2);
    }
  }
  builder.addByte(capabilityBitmask);
  return builder.toBytes();
}

/// A recognisable non-zero epoch, so a field that failed to make it onto the
/// wire reads back as [kUnknownSessionEpoch] rather than coincidentally
/// matching.
const kTestEpoch = 7;

void main() {
  late WakiPacketCodec codec;

  setUp(
    () => codec = WakiPacketCodec(
      'abc123abc123',
      SessionEpoch.startingAt(kTestEpoch),
    ),
  );
  tearDown(() => codec.release());

  group('v3 round trip', () {
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
        expect(roundTrip(heardIds: ['aaa111aaa111', 'bbb222bbb222']).heardIds, [
          'aaa111aaa111',
          'bbb222bbb222',
        ]);
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
        // Exactly what an older sender emits: header, isTalking, role, end —
        // codec.encodePresence can't produce this shape any more itself
        // (it always writes a heard-list section, real or the no-opinion
        // sentinel, plus a capability byte), so this is built by hand.
        final legacy = v3PresenceNoTrailer(
          'abc123abc123',
          'Old build',
          kTestEpoch,
          isTalking: false,
          role: SessionRole.host,
        );
        final decoded = codec.decode(legacy, '1.2.3.4')! as PresencePacket;
        expect(decoded.heardIds, isNull);
        // And #28's capability field, appended after the heard list, reads
        // the same "no opinion" way for the same reason.
        expect(decoded.capabilityBitmask, 0);
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
        final many = List.generate(
          40,
          (i) => 'id${i.toString().padLeft(10, '0')}',
        );
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

    group('capability (#28)', () {
      test("encodePresence's capability byte matches "
          'AudioCapabilityNegotiator.localBitmask', () {
        final packet =
            codec.decode(
                  codec.encodePresence('Pedram', false, role: SessionRole.peer),
                  '192.168.43.7',
                )!
                as PresencePacket;
        // Not hardcoded: reads the real, shipped
        // AudioCapabilityNegotiator.localBitmask rather than assuming its
        // value, so this stays correct as AudioFormatProfile.supported
        // grows (e.g. #29's media profiles).
        expect(
          packet.capabilityBitmask,
          AudioCapabilityNegotiator.localBitmask,
        );
      });

      test('the null-heardIds sentinel is not misread as a heard-id count '
          '(the point-to-point transport case)', () {
        // This is exactly what Bluetooth/WebRTC guest send: heardIds
        // null, a real (non-zero, once a future build can advertise one)
        // capability byte right after it. Before the no-opinion sentinel
        // existed, an encoder that wrote nothing for heardIds and then a
        // capability byte of 1 would have this decode as "one heard id,
        // of a length that reads off whatever byte comes next" — silently
        // wrong, not a crash.
        final packet = v3PresenceWithCapability(
          'abc123abc123',
          'Pedram',
          kTestEpoch,
          isTalking: true,
          role: SessionRole.host,
          heardIds: null,
          capabilityBitmask: 1,
        );
        final decoded = codec.decode(packet, '1.2.3.4')! as PresencePacket;
        expect(decoded.heardIds, isNull);
        expect(decoded.capabilityBitmask, 1);
        expect(decoded.senderName, 'Pedram');
      });

      test(
        'a non-zero capability byte round-trips exactly alongside a real heard list',
        () {
          final packet = v3PresenceWithCapability(
            'abc123abc123',
            'Pedram',
            kTestEpoch,
            isTalking: false,
            role: SessionRole.peer,
            heardIds: const ['aaa111aaa111'],
            capabilityBitmask: 3,
          );
          final decoded = codec.decode(packet, '1.2.3.4')! as PresencePacket;
          expect(decoded.heardIds, ['aaa111aaa111']);
          expect(decoded.capabilityBitmask, 3);
        },
      );

      test(
        'a non-zero capability byte round-trips exactly alongside an explicit empty heard list',
        () {
          final packet = v3PresenceWithCapability(
            'abc123abc123',
            'Pedram',
            kTestEpoch,
            isTalking: false,
            role: SessionRole.peer,
            heardIds: const [],
            capabilityBitmask: 1,
          );
          final decoded = codec.decode(packet, '1.2.3.4')! as PresencePacket;
          expect(decoded.heardIds, isEmpty);
          expect(decoded.capabilityBitmask, 1);
        },
      );

      test('an old-shaped packet (role + heard list, no capability byte) still '
          'decodes the heard list correctly and reads capability as 0', () {
        // A build that shipped after the heard list but before #28 —
        // the exact backward-compatibility case the capability byte's
        // placement (after, not before, heardIds) exists to preserve.
        final idBytes = utf8.encode('abc123abc123');
        final nameBytes = utf8.encode('Pedram');
        final builder = BytesBuilder(copy: false)
          ..addByte(kPresenceV3Byte)
          ..addByte(idBytes.length)
          ..add(idBytes)
          ..add(
            (ByteData(
              4,
            )..setUint32(0, kTestEpoch, Endian.little)).buffer.asUint8List(),
          )
          ..add(
            (ByteData(4)..setUint32(0, nameBytes.length, Endian.little)).buffer
                .asUint8List(),
          )
          ..add(nameBytes)
          ..addByte(0x00) // isTalking
          ..addByte(SessionRole.peer.wireByte)
          ..addByte(1) // heardIds count
          ..addByte(3) // "abc".length
          ..add(utf8.encode('abc'));
        final decoded =
            codec.decode(builder.toBytes(), '1.2.3.4')! as PresencePacket;
        expect(decoded.heardIds, ['abc']);
        expect(decoded.capabilityBitmask, 0);
      });
    });

    group('leaving flag (isLeaving)', () {
      test('round-trips true through encode/decode', () {
        final packet = codec.encodePresence(
          'Pedram',
          false,
          role: SessionRole.peer,
          isLeaving: true,
        );
        final decoded = codec.decode(packet, '1.2.3.4')! as PresencePacket;
        expect(decoded.isLeaving, isTrue);
      });

      test('defaults to false when not passed', () {
        final packet = codec.encodePresence(
          'Pedram',
          false,
          role: SessionRole.peer,
        );
        final decoded = codec.decode(packet, '1.2.3.4')! as PresencePacket;
        expect(decoded.isLeaving, isFalse);
      });

      test('an old-shaped packet (capability byte, no leaving byte) reads '
          'isLeaving as false', () {
        // Exactly what every build before this field shipped: the capability
        // byte is the last thing on the wire. The same "old build stops
        // reading first" backward compatibility as #28's capability byte
        // over the heard list before it.
        final packet = v3PresenceWithCapability(
          'abc123abc123',
          'Pedram',
          kTestEpoch,
          isTalking: false,
          role: SessionRole.peer,
          heardIds: null,
          capabilityBitmask: 1,
        );
        final decoded = codec.decode(packet, '1.2.3.4')! as PresencePacket;
        expect(decoded.capabilityBitmask, 1);
        expect(decoded.isLeaving, isFalse);
      });
    });

    test('a role this build has never heard of reads as unknown', () {
      final packet = codec.encodePresence(
        'Future',
        false,
        role: SessionRole.host,
      );
      // Role is 4 bytes from the end now: after it come the heard-list
      // no-opinion sentinel, the #28 capability byte, and the leaving byte
      // (heardIds is null here) — a later build may put anything in the
      // role byte itself.
      packet[packet.length - 4] = 99;

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
      final other = WakiPacketCodec(
        'ffffffffffff',
        SessionEpoch.startingAt(kTestEpoch),
      );
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

  group('session epoch', () {
    test('presence carries the epoch', () {
      final packet = codec.decode(
        codec.encodePresence('Pedram', true, role: SessionRole.host),
        '192.168.43.7',
      );

      expect(packet!.sessionEpoch, kTestEpoch);
      expect(packet.hasSessionEpoch, isTrue);
    });

    test('audio carries the epoch alongside the sequence', () {
      final packet = codec.decode(
        codec.encodeAudio(List.filled(320, 0.1), 'Pedram', 4242),
        '192.168.43.7',
      );

      expect(packet!.sessionEpoch, kTestEpoch);
      expect((packet as AudioPacket).seq, 4242);
    });

    // The epoch is read at encode time, not captured when the codec is built:
    // a rejoin has to change what goes on the wire without the transport
    // rebuilding its codec.
    test('a renewed epoch reaches the wire without rebuilding the codec', () {
      final epoch = SessionEpoch.startingAt(kTestEpoch);
      final live = WakiPacketCodec('abc123abc123', epoch);
      addTearDown(live.release);

      final before = live.decode(
        live.encodePresence('A', false, role: SessionRole.peer),
        'x',
      );
      epoch.renew();
      final after = live.decode(
        live.encodePresence('A', false, role: SessionRole.peer),
        'x',
      );

      expect(before!.sessionEpoch, kTestEpoch);
      expect(after!.sessionEpoch, kTestEpoch + 1);
    });

    test('a large epoch survives the uint32 field', () {
      final epoch = SessionEpoch.startingAt(0xFFFFFFFE);
      final live = WakiPacketCodec('abc123abc123', epoch);
      addTearDown(live.release);
      epoch.renew();

      final packet = live.decode(
        live.encodePresence('A', false, role: SessionRole.peer),
        'x',
      );
      expect(packet!.sessionEpoch, 0xFFFFFFFF);
    });
  });

  group('control packets', () {
    test('a ping round trips with its counters', () {
      final packet = codec.decodeControl(
        codec.encodePing(
          token: 77,
          lastTxSeq: 1200,
          lastRxSeq: 1180,
          audioRxPackets: 5000,
        ),
        '192.168.43.7',
      );

      expect(packet, isA<PingPacket>());
      expect(packet!.senderId, 'abc123abc123');
      expect(packet.sessionEpoch, kTestEpoch);
      expect(packet.token, 77);
      expect(packet.lastTxSeq, 1200);
      expect(packet.lastRxSeq, 1180);
      expect(packet.audioRxPackets, 5000);
    });

    test('a pong is distinguishable from a ping', () {
      final pong = codec.decodeControl(
        codec.encodePong(
          token: 77,
          lastTxSeq: 0,
          lastRxSeq: 0,
          audioRxPackets: 0,
        ),
        '1.2.3.4',
      );
      expect(pong, isA<PongPacket>());
      expect(pong!.token, 77);
    });

    // Control is answered by the transport and never surfaced to the session,
    // so the two decoders must not see each other's traffic.
    test('control does not decode as session traffic, or the reverse', () {
      final ping = codec.encodePing(
        token: 1,
        lastTxSeq: 0,
        lastRxSeq: 0,
        audioRxPackets: 0,
      );
      expect(codec.decode(ping, 'x'), isNull);

      final presence = codec.encodePresence(
        'Pedram',
        false,
        role: SessionRole.peer,
      );
      expect(codec.decodeControl(presence, 'x'), isNull);
    });

    test('the type byte alone identifies control, before any parsing', () {
      expect(WakiPacketCodec.isControl(kPingByte), isTrue);
      expect(WakiPacketCodec.isControl(kPongByte), isTrue);
      expect(WakiPacketCodec.isControl(kPresenceV3Byte), isFalse);
      expect(WakiPacketCodec.isControl(kOpusAudioV3Byte), isFalse);
    });

    test('a truncated control packet is rejected at every prefix length', () {
      final full = codec.encodePing(
        token: 5,
        lastTxSeq: 1,
        lastRxSeq: 2,
        audioRxPackets: 3,
      );
      for (var length = 0; length < full.length; length++) {
        expect(
          codec.decodeControl(Uint8List.sublistView(full, 0, length), 'x'),
          isNull,
          reason: 'prefix of length $length should not decode',
        );
      }
      expect(codec.decodeControl(full, 'x'), isNotNull);
    });

    // A pong that could not say which join it answered for would be unable to
    // do its job — a stale one would confirm a session that has ended.
    test('control always states an epoch', () {
      final epoch = SessionEpoch.startingAt(41);
      final live = WakiPacketCodec('abc123abc123', epoch);
      addTearDown(live.release);
      epoch.renew();

      final packet = live.decodeControl(
        live.encodePing(
          token: 1,
          lastTxSeq: 0,
          lastRxSeq: 0,
          audioRxPackets: 0,
        ),
        'x',
      );
      expect(packet!.sessionEpoch, 42);
    });
  });

  group('v2 compatibility', () {
    // A build from before the epoch expressed no opinion about which join it
    // was on. That has to stay distinguishable from a real epoch, because the
    // gate treats it as "do not judge" — grading it would put every peer on an
    // older build permanently out of the channel.
    test('presence decodes with no epoch stated', () {
      final packet = codec.decode(
        v2Presence(
          'ffffffffffff',
          'Older',
          isTalking: true,
          role: SessionRole.host,
        ),
        '192.168.43.7',
      );

      expect(packet, isA<PresencePacket>());
      expect(packet!.senderId, 'ffffffffffff');
      expect(packet.senderName, 'Older');
      expect(packet.sessionEpoch, kUnknownSessionEpoch);
      expect(packet.hasSessionEpoch, isFalse);
      expect((packet as PresencePacket).isTalking, isTrue);
      expect(packet.role, SessionRole.host);
    });
  });

  group('v1 compatibility', () {
    test('presence still decodes, falling back to the transport id', () {
      final packet = codec.decode(
        v1Presence('Legacy', isTalking: true),
        '192.168.43.7',
      );

      expect(packet, isA<PresencePacket>());
      expect(packet!.sessionEpoch, kUnknownSessionEpoch);
      expect(packet.senderId, '192.168.43.7');
      expect(packet.senderName, 'Legacy');
      expect((packet as PresencePacket).isTalking, isTrue);
      expect(packet.role, SessionRole.unknown);
    });
  });

  group('pre-role compatibility', () {
    test('a v2 presence without the role byte still decodes', () {
      // Byte-for-byte what a build from before roles puts on the wire: the
      // v2 header, isTalking, and nothing after it. Strips 4 trailing bytes
      // — role, the heard-list no-opinion sentinel, the #28 capability
      // byte, and the leaving byte (heardIds is null here) — all of which
      // postdate this format.
      final withRole = codec.encodePresence(
        'Older',
        true,
        role: SessionRole.host,
      );
      final withoutRole = Uint8List.sublistView(
        withRole,
        0,
        withRole.length - 4,
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

    // The epoch sits between the device id and the name length, so a packet
    // cut off inside it must not be read as a v2 header that happens to start
    // where the epoch does.
    test('a v3 packet truncated inside the epoch is rejected', () {
      final full = codec.encodePresence('Pedram', true, role: SessionRole.host);
      // 1 type + 1 idLen + 12 id = 14, then four epoch bytes.
      for (var length = 14; length < 18; length++) {
        expect(
          codec.decode(Uint8List.sublistView(full, 0, length), 'x'),
          isNull,
          reason: 'prefix of length $length should not decode',
        );
      }
    });

    test('a truncated v3 packet is rejected at every prefix length', () {
      final full = codec.encodePresence('Pedram', true, role: SessionRole.host);
      // Stops 4 bytes short (role, the heard-list sentinel, the #28
      // capability byte, and the leaving byte, in that order — heardIds is
      // null here): every one of those prefixes is not truncation but a
      // legitimate older format that decodes on purpose (covered above and
      // in the capability and leaving-flag groups).
      for (var length = 1; length < full.length - 4; length++) {
        expect(
          codec.decode(Uint8List.sublistView(full, 0, length), 'x'),
          isNull,
          reason: 'prefix of length $length should not decode',
        );
      }
      expect(codec.decode(full, 'x'), isNotNull);
    });

    test('an unknown type byte is dropped', () {
      expect(
        codec.decode(Uint8List.fromList([0x7f, 0, 0, 0, 0, 0]), 'x'),
        isNull,
      );
    });
  });

  group('channel id', () {
    /// A codec in a named channel. Separate from the shared [codec] because
    /// most of this file is about the v3 form, which is what a codec with no
    /// channel still emits.
    WakiPacketCodec inChannel(ChannelId id) {
      final membership = ChannelMembership()..join(id);
      return WakiPacketCodec(
        'abc123abc123',
        SessionEpoch.startingAt(kTestEpoch),
        membership,
      );
    }

    const channel = ChannelId(0xA83F21);

    // The property that keeps every existing session on exactly the bytes it
    // was already sending: v4 costs four bytes per frame and is paid only by
    // the packets that carry something for it.
    test('an open channel still sends v3, byte for byte', () {
      final open = WakiPacketCodec(
        'abc123abc123',
        SessionEpoch.startingAt(kTestEpoch),
        ChannelMembership(),
      );
      addTearDown(open.release);
      final withHolder = open.encodePresence(
        'Pedram',
        true,
        role: SessionRole.host,
      );
      final withoutHolder = codec.encodePresence(
        'Pedram',
        true,
        role: SessionRole.host,
      );
      expect(withHolder[0], kPresenceV3Byte);
      expect(withHolder, withoutHolder);
    });

    test('a named channel switches presence and audio to v4', () {
      final live = inChannel(channel);
      addTearDown(live.release);
      expect(
        live.encodePresence('Pedram', true, role: SessionRole.host)[0],
        kPresenceV4Byte,
      );
      final audio = live.encodeAudio(List.filled(320, 0.1), 'Pedram', 5);
      expect(audio[0], anyOf(kAudioV4Byte, kOpusAudioV4Byte));
    });

    test('and the channel survives the round trip on both', () {
      final live = inChannel(channel);
      addTearDown(live.release);
      final presence = live.decode(
        live.encodePresence('Pedram', true, role: SessionRole.host),
        'x',
      );
      expect(presence!.channelId.value, channel.value);
      // Everything the v3 header carried is still where it was.
      expect(presence.senderId, 'abc123abc123');
      expect(presence.senderName, 'Pedram');
      expect(presence.sessionEpoch, kTestEpoch);
      expect((presence as PresencePacket).role, SessionRole.host);

      final audio = live.decode(
        live.encodeAudio(List.filled(320, 0.1), 'Pedram', 5),
        'x',
      );
      expect(audio!.channelId.value, channel.value);
      expect((audio as AudioPacket).seq, 5);
    });

    // Read at encode time, like the epoch: the scanner adopts a channel from
    // another page and the running transport must pick it up without being
    // rebuilt.
    test('a channel joined mid-session reaches the wire immediately', () {
      final membership = ChannelMembership();
      final live = WakiPacketCodec(
        'abc123abc123',
        SessionEpoch.startingAt(kTestEpoch),
        membership,
      );
      addTearDown(live.release);
      expect(
        live.encodePresence('P', false, role: SessionRole.unknown)[0],
        kPresenceV3Byte,
      );
      membership.join(channel);
      final after = live.encodePresence('P', false, role: SessionRole.unknown);
      expect(after[0], kPresenceV4Byte);
      expect(live.decode(after, 'x')!.channelId.value, channel.value);
    });

    // The no-migration guarantee, from the receiving side.
    test('a v3 packet reads back as the open channel', () {
      final packet = codec.decode(
        codec.encodePresence('Pedram', true, role: SessionRole.host),
        'x',
      );
      expect(packet!.channelId.isOpen, isTrue);
    });

    test('so does a v2 one', () {
      final packet = codec.decode(
        v2Presence(
          'abc123abc123',
          'P',
          isTalking: false,
          role: SessionRole.unknown,
        ),
        'x',
      );
      expect(packet!.channelId.isOpen, isTrue);
    });

    test('a v4 packet truncated inside the channel is rejected', () {
      final live = inChannel(channel);
      addTearDown(live.release);
      final full = live.encodePresence('P', true, role: SessionRole.host);
      // See the v3 version of this test for why the bound is 4, not 1.
      for (var length = 1; length < full.length - 4; length++) {
        expect(
          live.decode(Uint8List.sublistView(full, 0, length), 'x'),
          isNull,
          reason: 'prefix of length $length should not decode',
        );
      }
      expect(live.decode(full, 'x'), isNotNull);
    });

    // Control stays on v3 deliberately — the peer map is the real gate, and
    // two more type bytes to restate it would cost more than the stray pong
    // they would save.
    test('control is unaffected by the channel', () {
      final live = inChannel(channel);
      addTearDown(live.release);
      final ping = live.encodePing(
        token: 1,
        lastTxSeq: 2,
        lastRxSeq: 3,
        audioRxPackets: 4,
      );
      expect(ping[0], kPingByte);
      final decoded = live.decodeControl(ping, 'x');
      expect(decoded, isA<PingPacket>());
      expect(decoded!.sessionEpoch, kTestEpoch);
    });
  });

  group('shared music as an independent stream (#30)', () {
    test('a media packet decodes as MediaAudioPacket, not AudioPacket', () {
      final samples = List<double>.generate(160, (i) => (i % 32) / 64);
      final packet = codec.decode(
        codec.encodeMediaAudio(samples, 'Pedram', 99),
        '10.0.0.9',
      );

      expect(packet, isA<MediaAudioPacket>());
      expect(packet!.senderId, 'abc123abc123');
      final media = packet as MediaAudioPacket;
      expect(media.seq, 99);
      expect(media.samples, hasLength(samples.length));
    });

    test('voice and media keep independent sequence spaces', () {
      final voice =
          codec.decode(
                codec.encodeAudio(List.filled(320, 0.1), 'Pedram', 5),
                'x',
              )!
              as AudioPacket;
      final media =
          codec.decode(
                codec.encodeMediaAudio(List.filled(320, 0.1), 'Pedram', 1),
                'x',
              )!
              as MediaAudioPacket;

      expect(voice.seq, 5);
      expect(media.seq, 1);
    });

    test('media always carries the channel, even while voice is on v3', () {
      // The open-channel codec ([codec]) still emits v3 for voice/presence
      // (see the "channel id" group above) — media has no such shorthand.
      final packet = codec.encodeMediaAudio(List.filled(320, 0.1), 'Pedram', 1);
      expect(packet[0], anyOf(kMediaAudioByte, kOpusMediaAudioByte));
      final decoded = codec.decode(packet, 'x');
      expect(decoded!.channelId.isOpen, isTrue);
    });

    test('a build that predates #30 drops an unrecognised media type byte '
        'rather than misreading it as voice', () {
      // What every current-build decoder does on an Opus media packet: the
      // type byte (0x10) matches none of the voice/presence/control cases,
      // so decode() falls through to null — dropped, not misparsed.
      expect(
        codec.decode(
          Uint8List.fromList([kOpusMediaAudioByte, 0, 0, 0, 0, 0]),
          'x',
        ),
        isNull,
      );
      expect(
        codec.decode(Uint8List.fromList([kMediaAudioByte, 0, 0, 0, 0, 0]), 'x'),
        isNull,
      );
    });

    test('resetMediaDecoders clears media state without touching voice', () {
      // Establish per-sender decoder state on both streams first.
      codec.decode(codec.encodeAudio(List.filled(320, 0.1), 'A', 1), 'x');
      codec.decode(codec.encodeMediaAudio(List.filled(320, 0.1), 'A', 1), 'x');

      // Neither call should throw, and both remain independently usable
      // afterward — the actual per-sender decoder maps are private, so this
      // exercises the public contract: reset one stream, the other keeps
      // decoding.
      codec.resetMediaDecoders();

      final voiceAfter = codec.decode(
        codec.encodeAudio(List.filled(320, 0.1), 'A', 2),
        'x',
      );
      final mediaAfter = codec.decode(
        codec.encodeMediaAudio(List.filled(320, 0.1), 'A', 2),
        'x',
      );
      expect(voiceAfter, isA<AudioPacket>());
      expect(mediaAfter, isA<MediaAudioPacket>());
    });

    test('media survives the sender name and epoch like voice does', () {
      final packet =
          codec.decode(
                codec.encodeMediaAudio(List.filled(320, 0.1), 'پدرام', 7),
                'x',
              )!
              as MediaAudioPacket;
      expect(packet.senderName, 'پدرام');
      expect(packet.senderId, 'abc123abc123');
      expect(packet.sessionEpoch, kTestEpoch);
    });
  });
}
