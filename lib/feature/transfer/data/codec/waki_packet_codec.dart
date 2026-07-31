import 'dart:convert';
import 'dart:typed_data';

import '../../domain/entity/session_role.dart';
import '../../domain/entity/waki_packet.dart';
import 'opus_audio_codec.dart';

const kPresenceByte = 0x01;
const kAudioByte = 0x02;
const kOpusAudioByte = 0x03;

// v2 of the same three messages, carrying the sender's stable device id ahead
// of the name. New type bytes rather than an extra field on the old ones: an
// older build reading 0x01 would take the id's first bytes as the name length
// and decode garbage, whereas an unknown type byte is simply dropped.
const kPresenceV2Byte = 0x04;
const kAudioV2Byte = 0x05;
const kOpusAudioV2Byte = 0x06;

/// Transport-agnostic encode/decode for the [WakiPacket] wire format.
///
/// Shared by every [TransferRepository] implementation (WiFi UDP, Bluetooth
/// Classic, BLE) so they all speak identical bytes — only how those bytes
/// reach the other device differs per transport.
///
/// Wire format, v2 — what this build sends (integers little-endian):
///   byte 0:        type (0x04 = presence, 0x05 = PCM16 audio, 0x06 = Opus)
///   byte 1:        sender device id length (uint8)
///   bytes 2..:     sender device id (ASCII hex, see [DeviceIdentity])
///   next 4:        sender name length (uint32)
///   next:          sender name (UTF-8)
///   presence:      1 byte isTalking (0/1) + 1 byte session role
///   audio:         4 bytes seq (uint32) + payload (PCM16 or one Opus packet)
///
/// The role byte was appended after v2 shipped, deliberately without a new
/// type: a build that predates it stops reading after isTalking, so its
/// decode is unaffected, and a packet from such a build is simply one byte
/// short — read back as [SessionRole.unknown].
///
/// v1 (types 0x01/0x02/0x03) is the same without the device-id prefix, and is
/// still decoded — the sender's id then falls back to whatever the transport
/// supplies. Nothing emits it any more: identity that came from the transport
/// was the bug the id exists to fix (see [DeviceIdentity]).
///
/// Audio is sent as Opus whenever libopus loaded ([OpusAudioCodec]); PCM16
/// remains both the fallback and understood on receive, so mixed app
/// versions still hear each other.
class WakiPacketCodec {
  WakiPacketCodec(this._deviceId) : _opus = OpusAudioCodec();

  /// Stamped on everything this codec encodes, so a receiver keys the roster
  /// and the jitter buffer on the device rather than on the address the
  /// datagram happened to arrive from.
  final String _deviceId;

  final OpusAudioCodec _opus;

  Uint8List encodeAudio(List<double> samples, String senderName, int seq) {
    final opusPacket = _opus.encode(samples);
    if (opusPacket != null) {
      return _buildAudioPacket(kOpusAudioV2Byte, senderName, seq, opusPacket);
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
      kAudioV2Byte,
      senderName,
      seq,
      audioData.buffer.asUint8List(),
    );
  }

  Uint8List _buildAudioPacket(
    int type,
    String senderName,
    int seq,
    Uint8List payload,
  ) {
    final builder = _startV2Packet(type, senderName);
    builder.add(
      (ByteData(4)..setUint32(0, seq, Endian.little)).buffer.asUint8List(),
    );
    builder.add(payload);
    return builder.toBytes();
  }

  Uint8List encodePresence(
    String senderName,
    bool isTalking, {
    required SessionRole role,
  }) {
    final builder = _startV2Packet(kPresenceV2Byte, senderName);
    builder.addByte(isTalking ? 0x01 : 0x00);
    builder.addByte(role.wireByte);
    return builder.toBytes();
  }

  /// Header every v2 message shares: type, device id, sender name.
  BytesBuilder _startV2Packet(int type, String senderName) {
    final idBytes = utf8.encode(_deviceId);
    final nameBytes = utf8.encode(senderName);
    final builder = BytesBuilder(copy: false);
    builder.addByte(type);
    // A single length byte: the id is 12 ASCII characters and a uint32 for it
    // would be three wasted bytes on every audio frame.
    builder.addByte(idBytes.length);
    builder.add(idBytes);
    builder.add(
      (ByteData(
        4,
      )..setUint32(0, nameBytes.length, Endian.little)).buffer.asUint8List(),
    );
    builder.add(nameBytes);
    return builder;
  }

  /// Decodes a single complete message.
  ///
  /// [fallbackSenderId] is what the transport knows about the sender (a UDP
  /// datagram's source IP, a Bluetooth peer id). It is only used for v1
  /// packets, which carry no identity of their own — a v2 packet's embedded
  /// device id always wins, because the transport's answer is not stable per
  /// device (see [DeviceIdentity]).
  WakiPacket? decode(Uint8List bytes, String fallbackSenderId) {
    if (bytes.isEmpty) return null;
    final type = bytes[0];

    // Where the v1 header starts, and who the sender is, are the only two
    // things that differ between the versions — the rest is byte-identical.
    final int headerEnd;
    final String senderId;
    if (_isV2(type)) {
      if (bytes.length < 2) return null;
      final idLen = bytes[1];
      if (bytes.length < 2 + idLen) return null;
      senderId = utf8.decode(bytes.sublist(2, 2 + idLen), allowMalformed: true);
      if (senderId.isEmpty) return null;
      headerEnd = 2 + idLen;
    } else {
      senderId = fallbackSenderId;
      headerEnd = 1;
    }

    if (bytes.length < headerEnd + 4) return null;
    final bd = ByteData.sublistView(bytes);
    final nameLen = bd.getUint32(headerEnd, Endian.little);
    final nameStart = headerEnd + 4;
    if (bytes.length < nameStart + nameLen) return null;

    final name = utf8.decode(
      bytes.sublist(nameStart, nameStart + nameLen),
      allowMalformed: true,
    );
    final bodyStart = nameStart + nameLen;

    if (type == kPresenceByte || type == kPresenceV2Byte) {
      if (bytes.length < bodyStart + 1) return null;
      return PresencePacket(
        senderId: senderId,
        senderName: name,
        isTalking: bytes[bodyStart] == 0x01,
        // Optional trailing byte — absent from every build before roles.
        role: bytes.length > bodyStart + 1
            ? SessionRole.fromWire(bytes[bodyStart + 1])
            : SessionRole.unknown,
      );
    }

    final isOpus = type == kOpusAudioByte || type == kOpusAudioV2Byte;
    final isPcm = type == kAudioByte || type == kAudioV2Byte;
    if (isOpus || isPcm) {
      if (bytes.length < bodyStart + 4) return null;
      final seq = bd.getUint32(bodyStart, Endian.little);
      final audioBytes = bytes.sublist(bodyStart + 4);
      if (audioBytes.isEmpty) return null;
      // Keyed on the sender id, so a per-sender Opus decoder follows the
      // device rather than the address it arrived from.
      final samples = isOpus
          ? _opus.decode(audioBytes, senderId)
          : _bytesToSamples(audioBytes);
      if (samples == null || samples.isEmpty) return null;
      return AudioPacket(
        senderId: senderId,
        senderName: name,
        samples: samples,
        seq: seq,
      );
    }
    return null;
  }

  static bool _isV2(int type) =>
      type == kPresenceV2Byte ||
      type == kAudioV2Byte ||
      type == kOpusAudioV2Byte;

  /// Frees native Opus state (call when the owning transport shuts down).
  void release() => _opus.release();

  /// Frees per-sender Opus decoder state (call after a detected reconnect).
  void resetDecoders() => _opus.resetDecoders();

  List<double> _bytesToSamples(Uint8List bytes) {
    final bd = ByteData.sublistView(bytes);
    final count = bytes.length ~/ 2;
    return List.generate(
      count,
      (i) => bd.getInt16(i * 2, Endian.little) / 32768.0,
    );
  }
}
