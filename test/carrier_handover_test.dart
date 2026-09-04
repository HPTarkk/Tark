import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:tark/feature/room/domain/entity/room.dart';
import 'package:tark/feature/room/domain/entity/room_carrier.dart';
import 'package:tark/feature/room/domain/service/room_member_transport_identity.dart';
import 'package:tark/feature/transfer/data/codec/carrier_handover_wire.dart';
import 'package:tark/feature/transfer/data/codec/transport_capability_control_codec.dart';
import 'package:tark/core/identity/session_epoch.dart';
import 'package:tark/feature/transfer/data/codec/waki_packet_codec.dart';
import 'package:tark/feature/transfer/domain/entity/transport_capability_advertisement.dart';

void main() {
  final roomId = RoomId('a' * 32);
  final hostId = RoomMemberId('b' * 24);
  final crypto = RoomMemberTransportIdentityCrypto();

  late RoomMemberTransportKeyPair issuer;
  late RoomMemberTransportKeyPair host;
  late RoomMemberTransportCertificate certificate;

  setUp(() async {
    issuer = await crypto.generateKeyPair();
    host = await crypto.generateKeyPair();
    certificate = await crypto.issueCertificate(
      roomId: roomId,
      memberId: hostId,
      memberPublicKey: host.publicKey,
      issuer: issuer,
    );
  });

  Future<RoomCarrierHandover> sign({
    int generation = 1,
    String ssid = 'Tark-Ride-4821',
    String passphrase = 'gallop-otter-9',
    DateTime? issuedAt,
  }) async {
    final at = issuedAt ?? DateTime.utc(2026, 9, 1, 20, 0);
    return RoomCarrierHandover(
      certificate: certificate,
      generation: generation,
      ssid: ssid,
      passphrase: passphrase,
      issuedAt: at,
      hostSignature: await crypto.signCarrierHandover(
        certificate: certificate,
        member: host,
        generation: generation,
        ssid: ssid,
        passphrase: passphrase,
        issuedAt: at,
      ),
    );
  }

  Future<bool> verify(RoomCarrierHandover handover) =>
      crypto.verifyCarrierHandover(
        certificate: handover.certificate,
        signature: handover.hostSignature,
        expectedRoomId: roomId,
        expectedIssuerPublicKey: issuer.publicKey,
        generation: handover.generation,
        ssid: handover.ssid,
        passphrase: handover.passphrase,
        issuedAt: handover.issuedAt,
      );

  group('the announcement survives the round trip', () {
    test('every field a receiver acts on comes back intact', () async {
      final original = await sign();
      final decoded = RoomCarrierHandover.decode(original.encode());

      expect(decoded.roomId, roomId);
      expect(decoded.hostMemberId, hostId);
      expect(decoded.generation, 1);
      expect(decoded.ssid, 'Tark-Ride-4821');
      expect(decoded.passphrase, 'gallop-otter-9');
      expect(decoded.issuedAt, DateTime.utc(2026, 9, 1, 20, 0));
      expect(decoded.hostSignature, original.hostSignature);
      expect(await verify(decoded), isTrue);
    });

    test('garbage is a FormatException, never a half-read handover', () {
      expect(
        () => RoomCarrierHandover.decode('not-a-handover'),
        throwsFormatException,
      );
      expect(() => RoomCarrierHandover.decode(''), throwsFormatException);
    });
  });

  group('signature covers what an attacker would want to change', () {
    test('a genuine signature does not carry a swapped SSID', () async {
      // The whole attack: keep a real announcement, point it at your own
      // access point. Every field is in the signed message precisely so this
      // fails.
      final genuine = await sign();
      final tampered = RoomCarrierHandover(
        certificate: genuine.certificate,
        generation: genuine.generation,
        ssid: 'Evil-AP',
        passphrase: genuine.passphrase,
        issuedAt: genuine.issuedAt,
        hostSignature: genuine.hostSignature,
      );
      expect(await verify(tampered), isFalse);
    });

    test('nor a swapped passphrase, generation or timestamp', () async {
      final genuine = await sign();
      Future<bool> withField(RoomCarrierHandover value) => verify(value);

      expect(
        await withField(
          RoomCarrierHandover(
            certificate: genuine.certificate,
            generation: genuine.generation,
            ssid: genuine.ssid,
            passphrase: 'other-secret',
            issuedAt: genuine.issuedAt,
            hostSignature: genuine.hostSignature,
          ),
        ),
        isFalse,
      );
      expect(
        await withField(
          RoomCarrierHandover(
            certificate: genuine.certificate,
            generation: 99,
            ssid: genuine.ssid,
            passphrase: genuine.passphrase,
            issuedAt: genuine.issuedAt,
            hostSignature: genuine.hostSignature,
          ),
        ),
        isFalse,
      );
      expect(
        await withField(
          RoomCarrierHandover(
            certificate: genuine.certificate,
            generation: genuine.generation,
            ssid: genuine.ssid,
            passphrase: genuine.passphrase,
            issuedAt: DateTime.utc(2026, 9, 1, 21, 0),
            hostSignature: genuine.hostSignature,
          ),
        ),
        isFalse,
      );
    });

    test('a certificate from another Room does not verify here', () async {
      final otherIssuer = await crypto.generateKeyPair();
      final stranger = await crypto.generateKeyPair();
      final strangerCert = await crypto.issueCertificate(
        roomId: roomId,
        memberId: hostId,
        memberPublicKey: stranger.publicKey,
        issuer: otherIssuer,
      );
      final at = DateTime.utc(2026, 9, 1, 20, 0);
      final signature = await crypto.signCarrierHandover(
        certificate: strangerCert,
        member: stranger,
        generation: 1,
        ssid: 'Evil-AP',
        passphrase: 'pw',
        issuedAt: at,
      );
      expect(
        await crypto.verifyCarrierHandover(
          certificate: strangerCert,
          signature: signature,
          expectedRoomId: roomId,
          expectedIssuerPublicKey: issuer.publicKey,
          generation: 1,
          ssid: 'Evil-AP',
          passphrase: 'pw',
          issuedAt: at,
        ),
        isFalse,
      );
    });
  });

  group('freshness', () {
    test('an announcement goes stale rather than steering a phone later', () {
      // Android rotates local-only hotspot credentials on every start, so an
      // old one names a network that no longer exists.
      final at = DateTime.utc(2026, 9, 1, 20, 0);
      final handover = RoomCarrierHandover(
        certificate: certificate,
        generation: 1,
        ssid: 's',
        passphrase: 'p',
        issuedAt: at,
        hostSignature: const [1],
      );
      expect(handover.isFresh(at), isTrue);
      expect(handover.isFresh(at.add(RoomCarrierHandover.freshness)), isTrue);
      expect(
        handover.isFresh(
          at.add(RoomCarrierHandover.freshness + const Duration(seconds: 1)),
        ),
        isFalse,
      );
    });

    test('a clock running backwards is not evidence of freshness', () {
      final at = DateTime.utc(2026, 9, 1, 20, 0);
      final handover = RoomCarrierHandover(
        certificate: certificate,
        generation: 1,
        ssid: 's',
        passphrase: 'p',
        issuedAt: at,
        hostSignature: const [1],
      );
      expect(handover.isFresh(at.subtract(const Duration(hours: 1))), isFalse);
    });
  });

  group('the wire record', () {
    test('round trips inside a control packet alongside capability', () async {
      final codec = TransportCapabilityControlCodec(
        WakiPacketCodec('abc123abc123', SessionEpoch.startingAt(7)),
      );
      final handover = (await sign()).encode();
      const capability = TransportCapabilityAdvertisement(
        canHostHotspot: true,
        bluetoothSupported: true,
        backgroundReady: true,
        batteryPercent: 77,
      );

      final ping = codec.encodePing(
        token: 42,
        lastTxSeq: 1,
        lastRxSeq: 2,
        audioRxPackets: 3,
        capability: capability,
        carrierHandover: handover,
      );
      final decoded = codec.decodeControl(ping, '10.0.0.2');

      expect(decoded, isNotNull);
      expect(decoded!.capability, capability);
      expect(decoded.carrierHandover, handover);
    });

    test('a pong keeps its route proof readable behind the handover', () async {
      // Ordering is load-bearing: the route proof's decoder asserts it reaches
      // the end of the datagram, so anything appended after it silently
      // destroys a perfectly good proof.
      final codec = TransportCapabilityControlCodec(
        WakiPacketCodec('abc123abc123', SessionEpoch.startingAt(7)),
      );
      final handover = (await sign()).encode();

      final pong = codec.encodePong(
        token: 42,
        lastTxSeq: 1,
        lastRxSeq: 2,
        audioRxPackets: 3,
        capability: const TransportCapabilityAdvertisement(
          canHostHotspot: false,
          bluetoothSupported: true,
          backgroundReady: true,
          batteryPercent: 50,
        ),
        routeProof: 'proof-payload',
        carrierHandover: handover,
      );
      final decoded = codec.decodeControl(pong, '10.0.0.2');

      expect(decoded!.carrierHandover, handover);
      expect(decoded.routeProof, 'proof-payload');
    });

    test('a packet without one decodes as no announcement', () {
      final codec = TransportCapabilityControlCodec(
        WakiPacketCodec('abc123abc123', SessionEpoch.startingAt(7)),
      );
      final ping = codec.encodePing(
        token: 1,
        lastTxSeq: 0,
        lastRxSeq: 0,
        audioRxPackets: 0,
      );
      expect(codec.decodeControl(ping, '10.0.0.2')!.carrierHandover, isNull);
    });

    test('an unknown version is refused rather than guessed at', () {
      final record = CarrierHandoverWire.encode('payload');
      final bumped = Uint8List.fromList(record)..[1] = 99;
      expect(CarrierHandoverWire.decode(bumped, 0), isNull);
      expect(CarrierHandoverWire.encodedLengthAt(bumped, 0), 0);
    });

    test('a truncated record reads as absent, not as a short payload', () {
      final record = CarrierHandoverWire.encode('payload');
      final truncated = Uint8List.sublistView(record, 0, record.length - 2);
      expect(CarrierHandoverWire.decode(truncated, 0), isNull);
      expect(CarrierHandoverWire.encodedLengthAt(truncated, 0), 0);
    });

    test('encodedLengthAt lets a caller step exactly past the record', () {
      final record = CarrierHandoverWire.encode('payload');
      expect(CarrierHandoverWire.encodedLengthAt(record, 0), record.length);
    });
  });
}
