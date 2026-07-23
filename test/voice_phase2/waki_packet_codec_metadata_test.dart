import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:tark/feature/transfer/data/codec/waki_packet_codec.dart';
import 'package:tark/feature/transfer/domain/entity/waki_packet.dart';

void main() {
  test('legacy audio packets still decode without metadata', () {
    final codec = WakiPacketCodec();
    addTearDown(codec.release);

    final bytes = codec.encodeAudio(List<double>.filled(160, 0.1), 'peer', 7);
    final packet = codec.decode(bytes, 'peer-id');

    expect(packet, isA<AudioPacket>());
    final audio = packet! as AudioPacket;
    expect(audio.seq, 7);
    expect(audio.metadata, isNull);
  });

  test('v2 audio packet carries monotonic timestamp metadata', () {
    final codec = WakiPacketCodec();
    addTearDown(codec.release);
    final metadata = AudioPacketMetadata(
      protocolVersion: 2,
      sequenceNumber: 42,
      captureTimestampUs: 1000,
      encodeCompleteTimestampUs: 1500,
      sendTimestampUs: 1750,
      senderMonotonicTimestampUs: 1750,
      codecIdentifier: 'pcm16',
      frameDurationMs: 20,
      sessionId: 'session-1',
      streamId: 'uplink',
    );

    final bytes = codec.encodeAudioWithMetadata(
      List<double>.filled(160, 0.2),
      'peer',
      metadata,
    );
    final packet = codec.decode(bytes, 'peer-id')! as AudioPacket;

    expect(packet.seq, 42);
    expect(packet.metadata?.protocolVersion, 2);
    expect(packet.metadata?.encodeLatencyUs, 500);
    expect(packet.metadata?.localQueueLatencyUs, 250);
    expect(packet.metadata?.sessionId, 'session-1');
  });

  test('invalid packets do not throw or crash parser', () {
    final codec = WakiPacketCodec();
    addTearDown(codec.release);

    expect(codec.decode(Uint8List.fromList([0x83, 0, 0]), 'peer-id'), isNull);
  });
}
