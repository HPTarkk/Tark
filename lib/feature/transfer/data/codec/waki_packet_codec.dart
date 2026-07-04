import 'dart:convert';
import 'dart:typed_data';

import '../../domain/entity/waki_packet.dart';
import 'opus_audio_codec.dart';

const kPresenceByte = 0x01;
const kAudioByte = 0x02;
const kOpusAudioByte = 0x03;

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
    final audioData = ByteData(samples.length * 2);
    for (int i = 0; i < samples.length; i++) {
      final clamped = samples[i].clamp(-1.0, 1.0);
      final intVal = (clamped * 32767).round().clamp(-32768, 32767);
      audioData.setInt16(i * 2, intVal, Endian.little);
    }
    return _buildAudioPacket(
        kAudioByte, senderName, seq, audioData.buffer.asUint8List());
  }

  Uint8List _buildAudioPacket(
      int type, String senderName, int seq, Uint8List payload) {
    final nameBytes = utf8.encode(senderName);
    final builder = BytesBuilder(copy: false);
    builder.addByte(type);
    builder.add((ByteData(4)..setUint32(0, nameBytes.length, Endian.little))
        .buffer
        .asUint8List());
    builder.add(nameBytes);
    builder.add(
        (ByteData(4)..setUint32(0, seq, Endian.little)).buffer.asUint8List());
    builder.add(payload);
    return builder.toBytes();
  }

  Uint8List encodePresence(String senderName, bool isTalking) {
    final nameBytes = utf8.encode(senderName);
    final builder = BytesBuilder(copy: false);
    builder.addByte(kPresenceByte);
    builder.add((ByteData(4)
          ..setUint32(0, nameBytes.length, Endian.little))
        .buffer
        .asUint8List());
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

    final name =
        utf8.decode(bytes.sublist(5, 5 + nameLen), allowMalformed: true);

    if (type == kPresenceByte) {
      if (bytes.length < 5 + nameLen + 1) return null;
      final isTalking = bytes[5 + nameLen] == 0x01;
      return PresencePacket(
          senderId: senderId, senderName: name, isTalking: isTalking);
    } else if (type == kAudioByte || type == kOpusAudioByte) {
      if (bytes.length < 5 + nameLen + 4) return null;
      final seqOffset = 5 + nameLen;
      final seq = bd.getUint32(seqOffset, Endian.little);
      final audioBytes = bytes.sublist(seqOffset + 4);
      if (audioBytes.isEmpty) return null;
      final samples = type == kOpusAudioByte
          ? _opus.decode(audioBytes, senderId)
          : _bytesToSamples(audioBytes);
      if (samples == null || samples.isEmpty) return null;
      return AudioPacket(
          senderId: senderId, senderName: name, samples: samples, seq: seq);
    }
    return null;
  }

  /// Frees native Opus state (call when the owning transport shuts down).
  void release() => _opus.release();

  List<double> _bytesToSamples(Uint8List bytes) {
    final bd = ByteData.sublistView(bytes);
    final count = bytes.length ~/ 2;
    return List.generate(
        count, (i) => bd.getInt16(i * 2, Endian.little) / 32768.0);
  }
}
