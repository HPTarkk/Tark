import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:tark/core/identity/session_epoch.dart';
import 'package:tark/feature/transfer/data/codec/media_feedback_control_codec.dart';
import 'package:tark/feature/transfer/data/codec/transport_capability_advertisement_wire.dart';
import 'package:tark/feature/transfer/data/codec/transport_capability_control_codec.dart';
import 'package:tark/feature/transfer/data/codec/waki_packet_codec.dart';
import 'package:tark/feature/transfer/domain/entity/media_receiver_feedback.dart';
import 'package:tark/feature/transfer/domain/entity/transport_capability_advertisement.dart';

void main() {
  const capability = TransportCapabilityAdvertisement(
    canHostHotspot: true,
    bluetoothSupported: true,
    backgroundReady: true,
    batteryPercent: 73,
    prefersHotspotHost: true,
  );

  WakiPacketCodec base() =>
      WakiPacketCodec('abcdef123456', SessionEpoch.startingAt(7));

  test('legacy decoder ignores capability-only control tail', () {
    final codec = TransportCapabilityControlCodec(base());
    final bytes = codec.encodePing(
      token: 11,
      lastTxSeq: 12,
      lastRxSeq: 13,
      audioRxPackets: 14,
      capability: capability,
    );

    final legacy = codec.base.decodeControl(bytes, '10.0.0.2');
    final decoded = codec.decodeControl(bytes, '10.0.0.2')!;

    expect(legacy, isNotNull);
    expect(legacy!.token, 11);
    expect(legacy.lastTxSeq, 12);
    expect(legacy.lastRxSeq, 13);
    expect(legacy.audioRxPackets, 14);
    expect(legacy.mediaReceiverFeedback, isNull);
    expect(decoded.packet, legacy);
    expect(decoded.capability, capability);
  });

  test('null capability preserves base control bytes exactly', () {
    final baseCodec = base();
    final codec = TransportCapabilityControlCodec(baseCodec);
    final raw = baseCodec.encodePing(
      token: 21,
      lastTxSeq: 22,
      lastRxSeq: 23,
      audioRxPackets: 24,
    );
    final wrapped = codec.encodePing(
      token: 21,
      lastTxSeq: 22,
      lastRxSeq: 23,
      audioRxPackets: 24,
    );

    expect(wrapped, raw);
    expect(codec.decodeControl(wrapped, 'peer')!.capability, isNull);
  });

  test('capability follows and preserves receiver feedback trailer', () {
    final baseCodec = base();
    final feedbackCodec = MediaFeedbackControlCodec(baseCodec);
    const feedback = MediaReceiverFeedback(
      queuedMs: 80,
      underruns: 2,
      outputStarvations: 3,
      trims: 4,
      overflowDrops: 5,
      staleDrops: 6,
      duplicateDrops: 7,
      resyncs: 8,
      concealedMs: 9,
    );
    final withFeedback = feedbackCodec.encodePong(
      token: 31,
      lastTxSeq: 32,
      lastRxSeq: 33,
      audioRxPackets: 34,
      mediaReceiverFeedback: feedback,
    );
    final bytes = TransportCapabilityControlCodec.appendCapability(
      withFeedback,
      capability,
    );
    final decoded = TransportCapabilityControlCodec(
      baseCodec,
    ).decodeControl(bytes, 'peer')!;
    final decodedFeedback = decoded.packet.mediaReceiverFeedback;

    expect(decodedFeedback, isNotNull);
    expect(decodedFeedback!.queuedMs, feedback.queuedMs);
    expect(decodedFeedback.underruns, feedback.underruns);
    expect(decodedFeedback.outputStarvations, feedback.outputStarvations);
    expect(decodedFeedback.trims, feedback.trims);
    expect(decodedFeedback.overflowDrops, feedback.overflowDrops);
    expect(decodedFeedback.staleDrops, feedback.staleDrops);
    expect(decodedFeedback.duplicateDrops, feedback.duplicateDrops);
    expect(decodedFeedback.resyncs, feedback.resyncs);
    expect(decodedFeedback.concealedMs, feedback.concealedMs);
    expect(decoded.capability, capability);
  });

  test('non-empty control sender name keeps capability offset correct', () {
    final baseCodec = base();
    final raw = baseCodec.encodePing(
      token: 35,
      lastTxSeq: 36,
      lastRxSeq: 37,
      audioRxPackets: 38,
    );

    final idLength = raw[1];
    final nameLengthOffset = 2 + idLength + 4;
    final bodyOffset = nameLengthOffset + 4;
    final named = Uint8List(raw.length + 1);
    named.setRange(0, bodyOffset, raw);
    ByteData.sublistView(
      named,
    ).setUint32(nameLengthOffset, 1, Endian.little);
    named[bodyOffset] = 0x78; // 'x'
    named.setRange(bodyOffset + 1, named.length, raw, bodyOffset);

    final bytes = TransportCapabilityControlCodec.appendCapability(
      named,
      capability,
    );
    final decoded = TransportCapabilityControlCodec(
      baseCodec,
    ).decodeControl(bytes, 'peer')!;

    expect(decoded.packet.token, 35);
    expect(decoded.packet.lastTxSeq, 36);
    expect(decoded.packet.lastRxSeq, 37);
    expect(decoded.packet.audioRxPackets, 38);
    expect(decoded.capability, capability);
  });

  test('truncated capability fails closed without damaging control packet', () {
    final baseCodec = base();
    final raw = baseCodec.encodePing(
      token: 41,
      lastTxSeq: 42,
      lastRxSeq: 43,
      audioRxPackets: 44,
    );
    final truncated = <int>[
      ...raw,
      TransportCapabilityAdvertisementWire.marker,
      TransportCapabilityAdvertisementWire.version,
    ];
    final decoded = TransportCapabilityControlCodec(
      baseCodec,
    ).decodeControl(Uint8List.fromList(truncated), 'peer')!;

    expect(decoded.packet.token, 41);
    expect(decoded.capability, isNull);
  });
}
