import 'dart:convert';
import 'dart:typed_data';

import '../../../../core/identity/session_epoch.dart';
import '../../domain/entity/control_packet.dart';
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

// v3 adds the sender's session epoch after the device id. Same reasoning as
// v1 → v2: a new type byte rather than a new field, because a v2 decoder
// reading 0x05 would take the epoch's bytes as the start of the name length
// and produce garbage, while 0x08 is simply dropped.
//
// The epoch could not ride as a trailing byte the way the presence role and
// heard list do. That trick works only where the message ends in a known
// place — an audio packet ends in a variable-length payload with no
// terminator, so anything appended is indistinguishable from more audio.
const kPresenceV3Byte = 0x07;
const kAudioV3Byte = 0x08;
const kOpusAudioV3Byte = 0x09;

// Transport control, on the same v3 header. Decoded into [ControlPacket] and
// answered by the transport itself, never surfaced to the session — see
// [WakiPacketCodec.decodeControl].
const kPingByte = 0x0A;
const kPongByte = 0x0B;

/// Transport-agnostic encode/decode for the [WakiPacket] wire format.
///
/// Shared by every [TransferRepository] implementation (WiFi UDP, Bluetooth
/// Classic, BLE) so they all speak identical bytes — only how those bytes
/// reach the other device differs per transport.
///
/// Wire format, v3 — what this build sends (integers little-endian):
///   byte 0:        type (0x07 = presence, 0x08 = PCM16 audio, 0x09 = Opus)
///   byte 1:        sender device id length (uint8)
///   bytes 2..:     sender device id (ASCII hex, see [DeviceIdentity])
///   next 4:        sender session epoch (uint32, see [SessionEpoch])
///   next 4:        sender name length (uint32)
///   next:          sender name (UTF-8)
///   presence:      1 byte isTalking (0/1) + 1 byte session role
///                  + optional heard-id list
///   audio:         4 bytes seq (uint32) + payload (PCM16 or one Opus packet)
///
/// The role byte was appended after v2 shipped, deliberately without a new
/// type: a build that predates it stops reading after isTalking, so its
/// decode is unaffected, and a packet from such a build is simply one byte
/// short — read back as [SessionRole.unknown]. The heard-id list was appended
/// after the role byte on the same terms.
///
/// v2 (types 0x04/0x05/0x06) is the same without the epoch, and v1
/// (0x01/0x02/0x03) without the device-id prefix either. Both are still
/// decoded, so a newer build hears an older one; a v1 sender's id falls back
/// to whatever the transport supplies, and a v1/v2 sender's epoch reads back
/// as [kUnknownSessionEpoch] — "expressed no opinion", never compared against
/// a real epoch and never a reason to drop anything.
///
/// Nothing emits v1 or v2 any more. Identity that came from the transport was
/// the bug the device id exists to fix (see [DeviceIdentity]), and a session
/// with no epoch cannot have its ghost packets told apart from its live ones
/// (see [SessionEpochGate]).
///
/// Audio is sent as Opus whenever libopus loaded ([OpusAudioCodec]); PCM16
/// remains both the fallback and understood on receive, so mixed app
/// versions still hear each other.
class WakiPacketCodec {
  WakiPacketCodec(this._deviceId, this._epoch) : _opus = OpusAudioCodec();

  /// Stamped on everything this codec encodes, so a receiver keys the roster
  /// and the jitter buffer on the device rather than on the address the
  /// datagram happened to arrive from.
  final String _deviceId;

  /// Read at encode time rather than captured in the constructor: the codec
  /// outlives any one session, and a rejoin has to change what goes on the
  /// wire without rebuilding it.
  final SessionEpoch _epoch;

  final OpusAudioCodec _opus;

  Uint8List encodeAudio(List<double> samples, String senderName, int seq) {
    final opusPacket = _opus.encode(samples);
    if (opusPacket != null) {
      return _buildAudioPacket(kOpusAudioV3Byte, senderName, seq, opusPacket);
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
      kAudioV3Byte,
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
    final builder = _startV3Packet(type, senderName);
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
    List<String>? heardIds,
  }) {
    final builder = _startV3Packet(kPresenceV3Byte, senderName);
    builder.addByte(isTalking ? 0x01 : 0x00);
    builder.addByte(role.wireByte);
    // Appended after the role byte, by the same reasoning that put the role
    // there: a build that predates this stops reading at the role and is
    // unaffected, so no new type byte (and no split channel of old/new peers)
    // is needed.
    //
    // Null means "no opinion" and writes nothing at all, which is deliberately
    // indistinguishable from an older build. An *empty* list is a statement —
    // "I can hear nobody" — and the receiver acts on it, so only a transport
    // that genuinely tracks who it hears may send one. Point-to-point
    // transports (Bluetooth, guest link) pass null: their peer set is the
    // connection itself, and claiming an empty list there would tell a
    // perfectly healthy peer it had gone mute.
    if (heardIds == null) return builder.toBytes();
    // Encoded first, then counted. Writing the count from the input list and
    // skipping an unencodable entry inside the loop would leave a count that
    // promises more ids than follow, and the decoder — correctly — throws the
    // whole list away as truncated. Ids are 12 ASCII characters so nothing is
    // ever dropped in practice; the ordering is what makes that guaranteed
    // rather than incidental.
    //
    // Capped so a busy channel can't push a presence datagram past a sane MTU.
    final encoded = <List<int>>[];
    for (final id in heardIds) {
      if (encoded.length >= _maxHeardIds) break;
      final idBytes = utf8.encode(id);
      // A single length byte, same as the sender id in the v2 header.
      if (idBytes.isEmpty || idBytes.length > 255) continue;
      encoded.add(idBytes);
    }
    builder.addByte(encoded.length);
    for (final idBytes in encoded) {
      builder.addByte(idBytes.length);
      builder.add(idBytes);
    }
    return builder.toBytes();
  }

  /// Ceiling on the heard list. Twelve peers is far beyond what a single
  /// walkie channel is for, and 12 × 13 bytes keeps presence comfortably
  /// inside one datagram on any link.
  static const _maxHeardIds = 12;

  /// Whether [typeByte] is transport control rather than session traffic.
  ///
  /// Takes the raw first byte so a caller can branch before any parsing
  /// happens. Audio arrives fifty times a second and control once — the common
  /// path must not pay for the rare one.
  static bool isControl(int typeByte) =>
      typeByte == kPingByte || typeByte == kPongByte;

  Uint8List encodePing({
    required int token,
    required int lastTxSeq,
    required int lastRxSeq,
    required int audioRxPackets,
  }) => _buildControl(kPingByte, token, lastTxSeq, lastRxSeq, audioRxPackets);

  Uint8List encodePong({
    required int token,
    required int lastTxSeq,
    required int lastRxSeq,
    required int audioRxPackets,
  }) => _buildControl(kPongByte, token, lastTxSeq, lastRxSeq, audioRxPackets);

  /// Control body: four uint32s after the shared header.
  ///
  /// The sender name is written as empty rather than omitted. Control rides the
  /// same header as everything else so one parser serves the whole wire format,
  /// and a name nobody displays would be bytes spent once a second forever.
  Uint8List _buildControl(
    int type,
    int token,
    int lastTxSeq,
    int lastRxSeq,
    int audioRxPackets,
  ) {
    final builder = _startV3Packet(type, '');
    final body = ByteData(16)
      ..setUint32(0, token, Endian.little)
      ..setUint32(4, lastTxSeq, Endian.little)
      ..setUint32(8, lastRxSeq, Endian.little)
      ..setUint32(12, audioRxPackets, Endian.little);
    builder.add(body.buffer.asUint8List());
    return builder.toBytes();
  }

  /// Decodes a ping or pong. Null for anything else, including a well-formed
  /// presence or audio packet — callers gate on [isControl] first.
  ControlPacket? decodeControl(Uint8List bytes, String fallbackSenderId) {
    if (bytes.isEmpty || !isControl(bytes[0])) return null;
    final header = _readV3Header(bytes, fallbackSenderId);
    if (header == null) return null;
    final bodyStart = header.bodyStart;
    if (bytes.length < bodyStart + 16) return null;
    final bd = ByteData.sublistView(bytes);
    final token = bd.getUint32(bodyStart, Endian.little);
    final lastTxSeq = bd.getUint32(bodyStart + 4, Endian.little);
    final lastRxSeq = bd.getUint32(bodyStart + 8, Endian.little);
    final audioRx = bd.getUint32(bodyStart + 12, Endian.little);
    return bytes[0] == kPingByte
        ? PingPacket(
            senderId: header.senderId,
            sessionEpoch: header.epoch,
            token: token,
            lastTxSeq: lastTxSeq,
            lastRxSeq: lastRxSeq,
            audioRxPackets: audioRx,
          )
        : PongPacket(
            senderId: header.senderId,
            sessionEpoch: header.epoch,
            token: token,
            lastTxSeq: lastTxSeq,
            lastRxSeq: lastRxSeq,
            audioRxPackets: audioRx,
          );
  }

  /// Header every v3 message shares: type, device id, session epoch, name.
  BytesBuilder _startV3Packet(int type, String senderName) {
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
      )..setUint32(0, _epoch.value, Endian.little)).buffer.asUint8List(),
    );
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
    final header = _readV3Header(bytes, fallbackSenderId);
    if (header == null) return null;
    final senderId = header.senderId;
    final epoch = header.epoch;
    final name = header.senderName;
    final bodyStart = header.bodyStart;
    final bd = ByteData.sublistView(bytes);

    if (type == kPresenceByte ||
        type == kPresenceV2Byte ||
        type == kPresenceV3Byte) {
      if (bytes.length < bodyStart + 1) return null;
      return PresencePacket(
        senderId: senderId,
        senderName: name,
        sessionEpoch: epoch,
        isTalking: bytes[bodyStart] == 0x01,
        // Optional trailing byte — absent from every build before roles.
        role: bytes.length > bodyStart + 1
            ? SessionRole.fromWire(bytes[bodyStart + 1])
            : SessionRole.unknown,
        // Optional again, and after the role: absent from every build before
        // the heard list existed.
        heardIds: _decodeHeardIds(bytes, bodyStart + 2),
      );
    }

    final isOpus =
        type == kOpusAudioByte ||
        type == kOpusAudioV2Byte ||
        type == kOpusAudioV3Byte;
    final isPcm =
        type == kAudioByte || type == kAudioV2Byte || type == kAudioV3Byte;
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
        sessionEpoch: epoch,
        samples: samples,
        seq: seq,
      );
    }
    return null;
  }

  /// Reads the length-prefixed device ids a presence packet ends with, from
  /// [start].
  ///
  /// Null — "the sender expressed no opinion" — for a packet that simply ends
  /// there (any build before the heard list, and every point-to-point
  /// transport), and also for anything that can't be read in full. Truncation
  /// is never reported as a partial list: the one consumer of this asks "is my
  /// id absent from it?", and answering yes from half a list is how a healthy
  /// link gets torn down and rebuilt for no reason.
  static List<String>? _decodeHeardIds(Uint8List bytes, int start) {
    if (start >= bytes.length) return null;
    final count = bytes[start];
    if (count == 0) return const [];
    final ids = <String>[];
    var offset = start + 1;
    for (var i = 0; i < count; i++) {
      if (offset >= bytes.length) return null;
      final len = bytes[offset];
      offset += 1;
      if (offset + len > bytes.length) return null;
      ids.add(
        utf8.decode(bytes.sublist(offset, offset + len), allowMalformed: true),
      );
      offset += len;
    }
    return ids;
  }

  /// The part of the header every message shares, whatever its version or
  /// whether it is session traffic or control.
  ///
  /// Where the name length starts, who the sender is, and whether an epoch was
  /// stated are the only things that differ between versions — from the name
  /// length on, all of them are byte-identical, which is what lets one parser
  /// serve presence, audio, ping and pong alike.
  ///
  /// Null for anything too short to hold what it claims. Every length check
  /// lives here rather than at the call sites, so a truncated datagram cannot
  /// reach a body reader at all.
  _V3Header? _readV3Header(Uint8List bytes, String fallbackSenderId) {
    if (bytes.isEmpty) return null;
    final type = bytes[0];

    final int headerEnd;
    final String senderId;
    var epoch = kUnknownSessionEpoch;
    final carriesId = _isV2(type) || _isV3(type) || isControl(type);
    if (carriesId) {
      if (bytes.length < 2) return null;
      final idLen = bytes[1];
      if (bytes.length < 2 + idLen) return null;
      senderId = utf8.decode(bytes.sublist(2, 2 + idLen), allowMalformed: true);
      if (senderId.isEmpty) return null;
      final idEnd = 2 + idLen;
      // Control was born on v3 and has no earlier form, so it always states an
      // epoch — a pong that could not say which join it answered for would be
      // unable to do the one job it has.
      if (_isV3(type) || isControl(type)) {
        if (bytes.length < idEnd + 4) return null;
        epoch = ByteData.sublistView(bytes).getUint32(idEnd, Endian.little);
        headerEnd = idEnd + 4;
      } else {
        headerEnd = idEnd;
      }
    } else {
      senderId = fallbackSenderId;
      headerEnd = 1;
    }

    if (bytes.length < headerEnd + 4) return null;
    final nameLen = ByteData.sublistView(
      bytes,
    ).getUint32(headerEnd, Endian.little);
    final nameStart = headerEnd + 4;
    if (bytes.length < nameStart + nameLen) return null;
    return _V3Header(
      senderId: senderId,
      epoch: epoch,
      senderName: utf8.decode(
        bytes.sublist(nameStart, nameStart + nameLen),
        allowMalformed: true,
      ),
      bodyStart: nameStart + nameLen,
    );
  }

  static bool _isV2(int type) =>
      type == kPresenceV2Byte ||
      type == kAudioV2Byte ||
      type == kOpusAudioV2Byte;

  static bool _isV3(int type) =>
      type == kPresenceV3Byte ||
      type == kAudioV3Byte ||
      type == kOpusAudioV3Byte;

  /// Tells the Opus encoder what the outgoing stream is carrying, so a music
  /// cast is not encoded through a speech model. See [OpusEncodeProfile].
  void setAudioProfile(OpusEncodeProfile profile) => _opus.setProfile(profile);

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

/// Everything a decoder needs before it knows what kind of message it has.
class _V3Header {
  const _V3Header({
    required this.senderId,
    required this.epoch,
    required this.senderName,
    required this.bodyStart,
  });

  final String senderId;
  final int epoch;
  final String senderName;

  /// Index of the first byte after the header — where the type-specific body
  /// begins.
  final int bodyStart;
}
