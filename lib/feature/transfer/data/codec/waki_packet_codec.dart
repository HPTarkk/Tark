import 'dart:convert';
import 'dart:typed_data';

import '../../../../core/identity/channel_id.dart';
import '../../../../core/identity/channel_membership.dart';
import '../../../../core/identity/session_epoch.dart';
import '../../domain/entity/control_packet.dart';
import '../../domain/entity/opus_tuning.dart';
import '../../domain/entity/session_role.dart';
import '../../domain/entity/waki_packet.dart';
import '../../domain/service/opus_tuner.dart';
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

// v4 adds the sender's channel id after the epoch. A new type byte again, for
// the third time and for the third identical reason: a v3 decoder reading 0x0D
// would take the channel's four bytes as the start of the name length and
// decode garbage, while an unrecognised type byte is dropped.
//
// The channel could not ride as a trailing field the way the presence role and
// heard list do, and the reason is the one that put the epoch in the header:
// an audio packet ends in a variable-length payload with no terminator, so
// anything appended to it is indistinguishable from more audio. Nor could it
// be presence-only — audio from a neighbouring channel would then be admitted
// until that channel's next presence tick, which is up to two seconds of
// someone else's conversation.
//
// **v4 is emitted only when there is a channel to state.** A session on
// [ChannelId.open] — which is every zero-setup Wi-Fi session, every Bluetooth
// link and every browser guest — keeps sending v3, byte for byte what it sent
// before. The four bytes are real on the transport that can least afford them
// (RFCOMM caps in-flight audio writes), and a version bump that costs bandwidth
// should be paid by the packets that carry something for it. Both versions
// decode through the same path, so a channel adopted mid-session simply changes
// which one goes out next.
const kPresenceV4Byte = 0x0C;
const kAudioV4Byte = 0x0D;
const kOpusAudioV4Byte = 0x0E;

/// Transport-agnostic encode/decode for the [WakiPacket] wire format.
///
/// Shared by every [TransferRepository] implementation (WiFi UDP, Bluetooth
/// Classic, BLE) so they all speak identical bytes — only how those bytes
/// reach the other device differs per transport.
///
/// Wire format, v4 — the widest form this build sends (integers
/// little-endian):
///   byte 0:        type (0x0C = presence, 0x0D = PCM16 audio, 0x0E = Opus)
///   byte 1:        sender device id length (uint8)
///   bytes 2..:     sender device id (ASCII hex, see [DeviceIdentity])
///   next 4:        sender session epoch (uint32, see [SessionEpoch])
///   next 4:        sender channel id (uint32, see [ChannelId]) — **v4 only**
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
/// v3 (types 0x07/0x08/0x09) is the same without the channel id, v2
/// (0x04/0x05/0x06) without the epoch either, and v1 (0x01/0x02/0x03) without
/// the device-id prefix on top of that. All are still decoded, so a newer
/// build hears an older one; a v1 sender's id falls back to whatever the
/// transport supplies, a v1/v2 sender's epoch reads back as
/// [kUnknownSessionEpoch], and anything below v4 reads back as
/// [ChannelId.open]. All three are "expressed no opinion" values — never
/// compared against a real one, and never a reason to drop anything.
///
/// **This build still emits v3 most of the time**, and that is deliberate
/// rather than a leftover: v4 is sent only while a channel is actually named.
/// See the type-byte block above.
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
  WakiPacketCodec(this._deviceId, this._epoch, [this._channel])
    : _opus = OpusAudioCodec();

  /// Stamped on everything this codec encodes, so a receiver keys the roster
  /// and the jitter buffer on the device rather than on the address the
  /// datagram happened to arrive from.
  final String _deviceId;

  /// Read at encode time rather than captured in the constructor: the codec
  /// outlives any one session, and a rejoin has to change what goes on the
  /// wire without rebuilding it.
  final SessionEpoch _epoch;

  /// Which channel to stamp, or null on a transport that cannot have more than
  /// one conversation on it.
  ///
  /// Optional rather than required because only the shared-medium transport has
  /// the problem: a Bluetooth link and a WebRTC guest link each *are* the
  /// channel, so there is nobody else on them to be separated from and the
  /// four bytes would buy nothing. Read at encode time, like the epoch, so a
  /// channel adopted by the scanner reaches the wire without rebuilding this.
  final ChannelMembership? _channel;

  ChannelId get _channelId => _channel?.current ?? ChannelId.open;

  final OpusAudioCodec _opus;

  Uint8List encodeAudio(List<double> samples, String senderName, int seq) {
    final opusPacket = _opus.encode(samples);
    if (opusPacket != null) {
      return _buildAudioPacket(
        _sessionType(kOpusAudioV3Byte, kOpusAudioV4Byte),
        senderName,
        seq,
        opusPacket,
      );
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
      _sessionType(kAudioV3Byte, kAudioV4Byte),
      senderName,
      seq,
      audioData.buffer.asUint8List(),
    );
  }

  /// The newest version that carries something: v4 while a channel is named,
  /// v3 otherwise. See the type-byte block above for why this is not simply
  /// "always the newest".
  int _sessionType(int v3Type, int v4Type) =>
      _channelId.isOpen ? v3Type : v4Type;

  Uint8List _buildAudioPacket(
    int type,
    String senderName,
    int seq,
    Uint8List payload,
  ) {
    final builder = _startPacket(type, senderName);
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
    final builder = _startPacket(
      _sessionType(kPresenceV3Byte, kPresenceV4Byte),
      senderName,
    );
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
  ///
  /// **Stays on the v3 header even inside a channel**, deliberately. A ping
  /// asks "can you reach me by unicast", and we only ever ping addresses the
  /// peer map holds — which [ChannelGate] has already filtered. A stray ping
  /// from a neighbouring channel costs us exactly one pong and gets its sender
  /// nowhere, because the roster it would need to enter is gated upstream. Two
  /// more type bytes to say something the peer map already says would be worse
  /// than the pong.
  Uint8List _buildControl(
    int type,
    int token,
    int lastTxSeq,
    int lastRxSeq,
    int audioRxPackets,
  ) {
    final builder = _startPacket(type, '');
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

  /// Header every message shares: type, device id, session epoch, then — on v4
  /// only — the channel id, then the name.
  ///
  /// The channel is written iff [type] is a v4 type, which [_sessionType] has
  /// already decided from the same value this reads. Keeping the decision in
  /// one place and the writing in another would let the two disagree, and a
  /// header whose length does not match its type byte is unparseable at the
  /// far end.
  BytesBuilder _startPacket(int type, String senderName) {
    final idBytes = utf8.encode(_deviceId);
    final nameBytes = utf8.encode(senderName);
    final builder = BytesBuilder(copy: false);
    builder.addByte(type);
    // A single length byte: the id is 12 ASCII characters and a uint32 for it
    // would be three wasted bytes on every audio frame.
    builder.addByte(idBytes.length);
    builder.add(idBytes);
    builder.add(_uint32(_epoch.value));
    if (_isV4(type)) builder.add(_uint32(_channelId.value));
    builder.add(_uint32(nameBytes.length));
    builder.add(nameBytes);
    return builder;
  }

  static Uint8List _uint32(int value) =>
      (ByteData(4)..setUint32(0, value, Endian.little)).buffer.asUint8List();

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
    final channelId = header.channelId;
    final name = header.senderName;
    final bodyStart = header.bodyStart;
    final bd = ByteData.sublistView(bytes);

    if (type == kPresenceByte ||
        type == kPresenceV2Byte ||
        type == kPresenceV3Byte ||
        type == kPresenceV4Byte) {
      if (bytes.length < bodyStart + 1) return null;
      return PresencePacket(
        senderId: senderId,
        senderName: name,
        sessionEpoch: epoch,
        channelId: channelId,
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
        type == kOpusAudioV3Byte ||
        type == kOpusAudioV4Byte;
    final isPcm =
        type == kAudioByte ||
        type == kAudioV2Byte ||
        type == kAudioV3Byte ||
        type == kAudioV4Byte;
    if (isOpus || isPcm) {
      if (bytes.length < bodyStart + 4) return null;
      final seq = bd.getUint32(bodyStart, Endian.little);
      final audioBytes = bytes.sublist(bodyStart + 4);
      if (audioBytes.isEmpty) return null;
      // Keyed on the sender id, so a per-sender Opus decoder follows the
      // device rather than the address it arrived from. The sequence goes in
      // too: a one-packet gap is what lets the decoder rebuild the missing
      // frame from this packet's in-band FEC copy.
      final decoded = isOpus ? _opus.decode(audioBytes, senderId, seq) : null;
      final samples = isOpus ? decoded?.samples : _bytesToSamples(audioBytes);
      if (samples == null || samples.isEmpty) return null;
      return AudioPacket(
        senderId: senderId,
        senderName: name,
        sessionEpoch: epoch,
        channelId: channelId,
        samples: samples,
        seq: seq,
        recoveredSamples: decoded?.recoveredPrevious,
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
    var channel = ChannelId.open;
    final carriesId =
        _isV2(type) || _isV3(type) || _isV4(type) || isControl(type);
    if (carriesId) {
      if (bytes.length < 2) return null;
      final idLen = bytes[1];
      if (bytes.length < 2 + idLen) return null;
      senderId = utf8.decode(bytes.sublist(2, 2 + idLen), allowMalformed: true);
      if (senderId.isEmpty) return null;
      var offset = 2 + idLen;
      // Control was born on v3 and has no earlier form, so it always states an
      // epoch — a pong that could not say which join it answered for would be
      // unable to do the one job it has.
      if (_isV3(type) || _isV4(type) || isControl(type)) {
        if (bytes.length < offset + 4) return null;
        epoch = ByteData.sublistView(bytes).getUint32(offset, Endian.little);
        offset += 4;
      }
      // v4 only. A v3 sender said nothing about a channel, which reads back as
      // [ChannelId.open] — "I have not asked to be separated from anyone" —
      // and is exactly what [ChannelGate] needs it to mean.
      if (_isV4(type)) {
        if (bytes.length < offset + 4) return null;
        channel = ChannelId.fromWire(
          ByteData.sublistView(bytes).getUint32(offset, Endian.little),
        );
        offset += 4;
      }
      headerEnd = offset;
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
      channelId: channel,
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

  static bool _isV4(int type) =>
      type == kPresenceV4Byte ||
      type == kAudioV4Byte ||
      type == kOpusAudioV4Byte;

  /// Tells the Opus encoder what the outgoing stream is carrying, so a music
  /// cast is not encoded through a speech model. See [OpusEncodeProfile].
  void setAudioProfile(OpusEncodeProfile profile) => _opus.setProfile(profile);

  /// Retunes the encoder for the link this codec is transmitting over — see
  /// [OpusTuner]. A no-op when the tuning is unchanged, so a transport can hand
  /// this its latest measurement on every tick.
  void applyTuning(OpusTuning tuning) => _opus.applyTuning(tuning);

  /// Whether the transmit path is running with in-band FEC, for the session
  /// log — it changes what a lossy link sounds like at the far end.
  bool get hasFec => _opus.hasFec;

  /// What the encoder is currently tuned to, for the session log.
  OpusTuning get tuning => _opus.tuning;

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
    required this.channelId,
    required this.senderName,
    required this.bodyStart,
  });

  final String senderId;
  final int epoch;

  /// [ChannelId.open] for anything below v4 — the sender named no channel.
  final ChannelId channelId;
  final String senderName;

  /// Index of the first byte after the header — where the type-specific body
  /// begins.
  final int bodyStart;
}
