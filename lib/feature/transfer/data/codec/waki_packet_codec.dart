import 'dart:convert';
import 'dart:typed_data';

import '../../../../core/audio/audio_format_profile.dart';
import '../../../../core/identity/channel_id.dart';
import '../../../../core/identity/channel_membership.dart';
import '../../../../core/identity/session_epoch.dart';
import '../../../audio/domain/media_receive_buffer.dart';
import '../../../audio/domain/media_receiver_feedback_adapter.dart';
import '../../domain/entity/control_packet.dart';
import '../../domain/entity/media_receiver_feedback.dart';
import '../../domain/entity/opus_tuning.dart';
import '../../domain/entity/session_role.dart';
import '../../domain/entity/waki_packet.dart';
import '../../domain/service/audio_capability_negotiator.dart';
import '../../domain/service/media_receiver_feedback_session.dart';
import '../../domain/service/opus_tuner.dart';
import 'media_receiver_feedback_wire.dart';
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

// #30 — Shared Music as an independent transport stream, alongside voice
// rather than mixed into it. Same reasoning as every version bump above:
// a media audio packet's body is seq + unterminated payload too, so a new
// type byte is the only safe way to add it — a build that predates #30
// simply drops an unrecognised type, which is exactly the fallback the
// roadmap wants for a peer that hasn't negotiated media (see
// AudioCapabilityNegotiator.media, TransferRepository.negotiatedMediaFormat).
//
// Unlike voice, there is no v1/v2/v3 media format to keep small for — this
// is the only shape it has ever had — so it always carries the full
// v4-style header (device id + epoch + channel), never a shorter one; see
// [WakiPacketCodec._isV4].
const kMediaAudioByte = 0x0F;
const kOpusMediaAudioByte = 0x10;

/// Transport-agnostic encode/decode for the [WakiPacket] wire format.
///
/// Shared by every [TransferRepository] implementation (WiFi UDP, Bluetooth
/// Classic, BLE) so they all speak identical bytes — only how those bytes
/// reach the other device differs per transport.
class WakiPacketCodec {
  WakiPacketCodec(this._deviceId, this._epoch, [this._channel])
    : _opus = OpusAudioCodec(),
      _mediaOpus = OpusAudioCodec() {
    _mediaOpus.setProfile(OpusEncodeProfile.music);
  }

  final String _deviceId;
  final SessionEpoch _epoch;
  final ChannelMembership? _channel;

  ChannelId get _channelId => _channel?.current ?? ChannelId.open;

  final OpusAudioCodec _opus;
  final OpusAudioCodec _mediaOpus;

  MediaReceiverFeedback? _cachedLocalReceiverFeedback;
  DateTime? _cachedLocalReceiverFeedbackAt;
  static const _receiverFeedbackSnapshotFor = Duration(milliseconds: 900);

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

  int _sessionType(int v3Type, int v4Type) =>
      _channelId.isOpen ? v3Type : v4Type;

  Uint8List encodeMediaAudio(List<double> samples, String senderName, int seq) {
    final opusPacket = _mediaOpus.encode(samples);
    if (opusPacket != null) {
      return _buildAudioPacket(
        kOpusMediaAudioByte,
        senderName,
        seq,
        opusPacket,
      );
    }
    final audioData = ByteData(samples.length * 2);
    for (int i = 0; i < samples.length; i++) {
      final clamped = samples[i].clamp(-1.0, 1.0);
      final intVal = (clamped * 32767).round().clamp(-32768, 32767);
      audioData.setInt16(i * 2, intVal, Endian.little);
    }
    return _buildAudioPacket(
      kMediaAudioByte,
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
    bool isLeaving = false,
  }) {
    final builder = _startPacket(
      _sessionType(kPresenceV3Byte, kPresenceV4Byte),
      senderName,
    );
    builder.addByte(isTalking ? 0x01 : 0x00);
    builder.addByte(role.wireByte);
    if (heardIds == null) {
      builder.addByte(_kNoHeardIdsOpinion);
    } else {
      final encoded = <List<int>>[];
      for (final id in heardIds) {
        if (encoded.length >= _maxHeardIds) break;
        final idBytes = utf8.encode(id);
        if (idBytes.isEmpty || idBytes.length > 255) continue;
        encoded.add(idBytes);
      }
      builder.addByte(encoded.length);
      for (final idBytes in encoded) {
        builder.addByte(idBytes.length);
        builder.add(idBytes);
      }
    }
    builder.addByte(AudioCapabilityNegotiator.localBitmask);
    builder.addByte(isLeaving ? 0x01 : 0x00);
    return builder.toBytes();
  }

  static const _maxHeardIds = 12;
  static const _kNoHeardIdsOpinion = 0xFF;

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

  /// Control body remains the original four uint32s. #41 appends an optional
  /// bounded receiver-health trailer after those 16 bytes. Old decoders stop
  /// at the fields they know, so the extension is byte-compatible; no new
  /// packet type or protocol version is introduced.
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
    final feedback = _localReceiverFeedback();
    if (feedback != null) {
      builder.add(MediaReceiverFeedbackWire.encode(feedback));
    }
    return builder.toBytes();
  }

  MediaReceiverFeedback? _localReceiverFeedback() {
    final now = DateTime.now();
    final sampledAt = _cachedLocalReceiverFeedbackAt;
    if (sampledAt != null &&
        now.difference(sampledAt) < _receiverFeedbackSnapshotFor) {
      return _cachedLocalReceiverFeedback;
    }
    final health = MediaReceiveBuffer.takeActiveHealthWindow();
    _cachedLocalReceiverFeedback = health == null
        ? null
        : MediaReceiverFeedbackAdapter.fromHealth(health);
    _cachedLocalReceiverFeedbackAt = now;
    return _cachedLocalReceiverFeedback;
  }

  void _clearLocalReceiverFeedbackSnapshot() {
    _cachedLocalReceiverFeedback = null;
    _cachedLocalReceiverFeedbackAt = null;
  }

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
    final feedback = MediaReceiverFeedbackWire.decode(bytes, bodyStart + 16);
    if (bytes[0] == kPingByte) {
      return PingPacket(
        senderId: header.senderId,
        sessionEpoch: header.epoch,
        token: token,
        lastTxSeq: lastTxSeq,
        lastRxSeq: lastRxSeq,
        audioRxPackets: audioRx,
        mediaReceiverFeedback: feedback,
      );
    }
    MediaReceiverFeedbackSession.shared.stagePong(
      address: fallbackSenderId,
      peerId: header.senderId,
      token: token,
      feedback: feedback,
    );
    return PongPacket(
      senderId: header.senderId,
      sessionEpoch: header.epoch,
      token: token,
      lastTxSeq: lastTxSeq,
      lastRxSeq: lastRxSeq,
      audioRxPackets: audioRx,
      mediaReceiverFeedback: feedback,
    );
  }

  BytesBuilder _startPacket(int type, String senderName) {
    final idBytes = utf8.encode(_deviceId);
    final nameBytes = utf8.encode(senderName);
    final builder = BytesBuilder(copy: false);
    builder.addByte(type);
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
      final (heardIds, afterHeardIds) = _decodeHeardIds(bytes, bodyStart + 2);
      final hasCapability = afterHeardIds < bytes.length;
      final leavingOffset = afterHeardIds + 1;
      return PresencePacket(
        senderId: senderId,
        senderName: name,
        sessionEpoch: epoch,
        channelId: channelId,
        isTalking: bytes[bodyStart] == 0x01,
        role: bytes.length > bodyStart + 1
            ? SessionRole.fromWire(bytes[bodyStart + 1])
            : SessionRole.unknown,
        heardIds: heardIds,
        capabilityBitmask: hasCapability ? bytes[afterHeardIds] : 0,
        isLeaving:
            hasCapability &&
            leavingOffset < bytes.length &&
            bytes[leavingOffset] == 0x01,
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

    final isMediaOpus = type == kOpusMediaAudioByte;
    final isMediaPcm = type == kMediaAudioByte;
    if (isMediaOpus || isMediaPcm) {
      if (bytes.length < bodyStart + 4) return null;
      final seq = bd.getUint32(bodyStart, Endian.little);
      final audioBytes = bytes.sublist(bodyStart + 4);
      if (audioBytes.isEmpty) return null;
      final decoded = isMediaOpus
          ? _mediaOpus.decode(audioBytes, senderId, seq)
          : null;
      final samples = isMediaOpus
          ? decoded?.samples
          : _bytesToSamples(audioBytes);
      if (samples == null || samples.isEmpty) return null;
      return MediaAudioPacket(
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

  static (List<String>? ids, int end) _decodeHeardIds(
    Uint8List bytes,
    int start,
  ) {
    if (start >= bytes.length) return (null, start);
    final count = bytes[start];
    if (count > _maxHeardIds) return (null, start + 1);
    if (count == 0) return (const [], start + 1);
    final ids = <String>[];
    var offset = start + 1;
    for (var i = 0; i < count; i++) {
      if (offset >= bytes.length) return (null, bytes.length);
      final len = bytes[offset];
      offset += 1;
      if (offset + len > bytes.length) return (null, bytes.length);
      ids.add(
        utf8.decode(bytes.sublist(offset, offset + len), allowMalformed: true),
      );
      offset += len;
    }
    return (ids, offset);
  }

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
      if (_isV3(type) || _isV4(type) || isControl(type)) {
        if (bytes.length < offset + 4) return null;
        epoch = ByteData.sublistView(bytes).getUint32(offset, Endian.little);
        offset += 4;
      }
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
      type == kOpusAudioV4Byte ||
      type == kMediaAudioByte ||
      type == kOpusMediaAudioByte;

  void setAudioProfile(OpusEncodeProfile profile) => _opus.setProfile(profile);

  void applyTuning(OpusTuning tuning) => _opus.applyTuning(tuning);

  bool get hasFec => _opus.hasFec;

  OpusTuning get tuning => _opus.tuning;

  void release() {
    _clearLocalReceiverFeedbackSnapshot();
    _opus.release();
    _mediaOpus.release();
  }

  void resetDecoders() => _opus.resetDecoders();

  void resetMediaDecoders() {
    _clearLocalReceiverFeedbackSnapshot();
    _mediaOpus.resetDecoders();
  }

  void setFormatProfile(AudioFormatProfile profile) =>
      _opus.setFormatProfile(profile);

  void setMediaFormatProfile(AudioFormatProfile profile) =>
      _mediaOpus.setFormatProfile(profile);

  void applyMediaTuning(OpusTuning tuning) => _mediaOpus.applyTuning(tuning);

  bool get hasMediaFec => _mediaOpus.hasFec;

  OpusTuning get mediaTuning => _mediaOpus.tuning;

  List<double> _bytesToSamples(Uint8List bytes) {
    final bd = ByteData.sublistView(bytes);
    final count = bytes.length ~/ 2;
    return List.generate(
      count,
      (i) => bd.getInt16(i * 2, Endian.little) / 32768.0,
    );
  }
}

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
  final ChannelId channelId;
  final String senderName;
  final int bodyStart;
}
