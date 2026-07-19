import 'dart:convert';
import 'dart:typed_data';

import '../../domain/entity/waki_packet.dart';
import 'opus_audio_codec.dart';

const kPresenceByte = 0x01;
const kAudioByte = 0x02;
const kOpusAudioByte = 0x03;
const kOpusAudioV2Byte = 0x83;

/// Transport-agnostic encode/decode for the [WakiPacket] wire format.
///
/// Shared by every [TransferRepository] implementation (WiFi UDP, Bluetooth
/// Classic, BLE) so they all speak identical bytes — only how those bytes
/// reach the other device differs per transport.
///
/// Wire format (all multi-byte integers little-endian):
///   byte 0:        type (0x01 = presence, 0x02 = PCM16 audio, 0x03 = Opus)
///   bytes 1-4:     sender name length (uint32)
///   bytes 5..:     sender name (UTF-8)
///   presence:      1 byte isTalking (0/1)
///   audio:         4 bytes seq (uint32) + payload (PCM16 or one Opus packet)
///
/// Audio is sent as Opus whenever libopus loaded ([OpusAudioCodec]); PCM16
/// remains both the fallback and understood on receive, so mixed app
/// versions still hear each other.
class WakiPacketCodec {
  WakiPacketCodec() : _opus = OpusAudioCodec();

  final OpusAudioCodec _opus;

  Uint8List encodeAudio(List<double> samples, String senderName, int seq) {
    final opusPacket = _opus.encode(samples);
    if (opusPacket != null) {
      return _buildAudioPacket(kOpusAudioByte, senderName, seq, opusPacket);
    }
    // PCM16 fallback — halves float32 bandwidth with no audible quality
    // loss for voice.
    return _buildAudioPacket(kAudioByte, senderName, seq, _pcm16(samples));
  }


  Uint8List encodeAudioWithMetadata(
    List<double> samples,
    String senderName,
    AudioPacketMetadata metadata,
  ) {
    final opusPacket = _opus.encode(samples);
    final payload = opusPacket ?? _pcm16(samples);
    final codec = opusPacket != null ? 'opus' : 'pcm16';
    final effective = AudioPacketMetadata(
      protocolVersion: 2,
      sequenceNumber: metadata.sequenceNumber,
      captureTimestampUs: metadata.captureTimestampUs,
      encodeCompleteTimestampUs: metadata.encodeCompleteTimestampUs,
      sendTimestampUs: metadata.sendTimestampUs,
      senderMonotonicTimestampUs: metadata.senderMonotonicTimestampUs,
      codecIdentifier: metadata.codecIdentifier ?? codec,
      frameDurationMs: metadata.frameDurationMs,
      sessionId: metadata.sessionId,
      streamId: metadata.streamId,
    );
    return _buildAudioPacket(
      kOpusAudioV2Byte,
      senderName,
      metadata.sequenceNumber,
      _metadataEnvelope(effective, payload),
    );
  }

  Uint8List _buildAudioPacket(
    int type,
    String senderName,
    int seq,
    Uint8List payload,
  ) {
    final nameBytes = utf8.encode(senderName);
    final builder = BytesBuilder(copy: false);
    builder.addByte(type);
    builder.add(
      (ByteData(
        4,
      )..setUint32(0, nameBytes.length, Endian.little)).buffer.asUint8List(),
    );
    builder.add(nameBytes);
    builder.add(
      (ByteData(4)..setUint32(0, seq, Endian.little)).buffer.asUint8List(),
    );
    builder.add(payload);
    return builder.toBytes();
  }

  Uint8List encodePresence(String senderName, bool isTalking) {
    final nameBytes = utf8.encode(senderName);
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

  /// Decodes a single complete message. [senderId] is supplied by the
  /// transport (a UDP datagram's source IP, or a Bluetooth peer id) since
  /// the wire format itself carries no address — only the sender's display
  /// name.
  WakiPacket? decode(Uint8List bytes, String senderId) {
    if (bytes.length < 6) return null;
    final type = bytes[0];
    final bd = ByteData.sublistView(bytes);
    final nameLen = bd.getUint32(1, Endian.little);
    if (bytes.length < 5 + nameLen) return null;

    final name = utf8.decode(
      bytes.sublist(5, 5 + nameLen),
      allowMalformed: true,
    );

    if (type == kPresenceByte) {
      if (bytes.length < 5 + nameLen + 1) return null;
      final isTalking = bytes[5 + nameLen] == 0x01;
      return PresencePacket(
        senderId: senderId,
        senderName: name,
        isTalking: isTalking,
      );
    } else if (type == kAudioByte ||
        type == kOpusAudioByte ||
        type == kOpusAudioV2Byte) {
      if (bytes.length < 5 + nameLen + 4) return null;
      final seqOffset = 5 + nameLen;
      final seq = bd.getUint32(seqOffset, Endian.little);
      final audioBytes = bytes.sublist(seqOffset + 4);
      if (audioBytes.isEmpty) return null;
      final envelope = type == kOpusAudioV2Byte
          ? _decodeMetadataEnvelope(audioBytes, seq)
          : null;
      final payload = envelope?.payload ?? audioBytes;
      final samples = type == kAudioByte
          ? _bytesToSamples(payload)
          : _opus.decode(payload, senderId);
      if (samples == null || samples.isEmpty) return null;
      return AudioPacket(
        senderId: senderId,
        senderName: name,
        samples: samples,
        seq: seq,
        metadata: envelope?.metadata,
      );
    }
    return null;
  }

  /// Frees native Opus state (call when the owning transport shuts down).
  void release() => _opus.release();

  /// Frees per-sender Opus decoder state (call after a detected reconnect).
  void resetDecoders() => _opus.resetDecoders();

  Uint8List _pcm16(List<double> samples) {
    final audioData = ByteData(samples.length * 2);
    for (int i = 0; i < samples.length; i++) {
      final clamped = samples[i].clamp(-1.0, 1.0);
      final intVal = (clamped * 32767).round().clamp(-32768, 32767);
      audioData.setInt16(i * 2, intVal, Endian.little);
    }
    return audioData.buffer.asUint8List();
  }

  Uint8List _metadataEnvelope(AudioPacketMetadata metadata, Uint8List payload) {
    final metadataBytes = utf8.encode(jsonEncode({
      'v': metadata.protocolVersion,
      'seq': metadata.sequenceNumber,
      'captureUs': metadata.captureTimestampUs,
      'encodeDoneUs': metadata.encodeCompleteTimestampUs,
      'sendUs': metadata.sendTimestampUs,
      'monoUs': metadata.senderMonotonicTimestampUs,
      'codec': metadata.codecIdentifier,
      'frameMs': metadata.frameDurationMs,
      'sessionId': metadata.sessionId,
      'streamId': metadata.streamId,
    }));
    final builder = BytesBuilder(copy: false)
      ..add((ByteData(2)..setUint16(0, metadataBytes.length, Endian.little)).buffer.asUint8List())
      ..add(metadataBytes)
      ..add(payload);
    return builder.toBytes();
  }

  _DecodedAudioEnvelope? _decodeMetadataEnvelope(Uint8List bytes, int fallbackSeq) {
    if (bytes.length < 2) return null;
    final metadataLength = ByteData.sublistView(bytes, 0, 2).getUint16(0, Endian.little);
    if (bytes.length < 2 + metadataLength) return null;
    try {
      final map = jsonDecode(utf8.decode(bytes.sublist(2, 2 + metadataLength))) as Map<String, dynamic>;
      return _DecodedAudioEnvelope(
        AudioPacketMetadata(
          protocolVersion: (map['v'] as num?)?.toInt() ?? 2,
          sequenceNumber: (map['seq'] as num?)?.toInt() ?? fallbackSeq,
          captureTimestampUs: (map['captureUs'] as num?)?.toInt(),
          encodeCompleteTimestampUs: (map['encodeDoneUs'] as num?)?.toInt(),
          sendTimestampUs: (map['sendUs'] as num?)?.toInt(),
          senderMonotonicTimestampUs: (map['monoUs'] as num?)?.toInt(),
          codecIdentifier: map['codec'] as String?,
          frameDurationMs: (map['frameMs'] as num?)?.toInt(),
          sessionId: map['sessionId'] as String?,
          streamId: map['streamId'] as String?,
        ),
        bytes.sublist(2 + metadataLength),
      );
    } on FormatException {
      return null;
    } on TypeError {
      return null;
    }
  }

  List<double> _bytesToSamples(Uint8List bytes) {
    final bd = ByteData.sublistView(bytes);
    final count = bytes.length ~/ 2;
    return List.generate(
      count,
      (i) => bd.getInt16(i * 2, Endian.little) / 32768.0,
    );
  }
}


class _DecodedAudioEnvelope {
  const _DecodedAudioEnvelope(this.metadata, this.payload);

  final AudioPacketMetadata metadata;
  final Uint8List payload;
}
