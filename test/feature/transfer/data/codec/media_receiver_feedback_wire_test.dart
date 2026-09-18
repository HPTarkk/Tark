import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:tark/feature/transfer/data/codec/media_receiver_feedback_wire.dart';
import 'package:tark/feature/transfer/domain/entity/media_receiver_feedback.dart';

void main() {
  const feedback = MediaReceiverFeedback(
    queuedMs: 120,
    underruns: 2,
    outputStarvations: 3,
    trims: 4,
    overflowDrops: 5,
    staleDrops: 6,
    duplicateDrops: 7,
    resyncs: 8,
    concealedMs: 90,
  );

  test('v1 receiver feedback round-trips exactly', () {
    final encoded = MediaReceiverFeedbackWire.encode(feedback);
    final decoded = MediaReceiverFeedbackWire.decode(encoded, 0);

    expect(decoded, isNotNull);
    expect(decoded!.queuedMs, 120);
    expect(decoded.underruns, 2);
    expect(decoded.outputStarvations, 3);
    expect(decoded.trims, 4);
    expect(decoded.overflowDrops, 5);
    expect(decoded.staleDrops, 6);
    expect(decoded.duplicateDrops, 7);
    expect(decoded.resyncs, 8);
    expect(decoded.concealedMs, 90);
  });

  test('missing trailer is unconfirmed rather than a clean receiver', () {
    expect(MediaReceiverFeedbackWire.decode(Uint8List(16), 16), isNull);
  });

  test('truncated trailer fails closed as unconfirmed', () {
    final encoded = MediaReceiverFeedbackWire.encode(feedback);
    final truncated = Uint8List.sublistView(encoded, 0, encoded.length - 1);
    expect(MediaReceiverFeedbackWire.decode(truncated, 0), isNull);
  });

  test('unknown trailer version fails closed as unconfirmed', () {
    final encoded = MediaReceiverFeedbackWire.encode(feedback);
    encoded[0] = 99;
    expect(MediaReceiverFeedbackWire.decode(encoded, 0), isNull);
  });

  test('values are bounded to unsigned 16-bit wire range', () {
    final encoded = MediaReceiverFeedbackWire.encode(
      const MediaReceiverFeedback(
        queuedMs: -1,
        underruns: 70000,
        outputStarvations: 0,
        trims: 0,
        overflowDrops: 0,
        staleDrops: 0,
        duplicateDrops: 0,
        resyncs: 0,
        concealedMs: 100000,
      ),
    );
    final decoded = MediaReceiverFeedbackWire.decode(encoded, 0)!;

    expect(decoded.queuedMs, 0);
    expect(decoded.underruns, 0xffff);
    expect(decoded.concealedMs, 0xffff);
  });

  test('decoder reads trailer at additive offset after legacy body', () {
    final legacyBody = Uint8List(16);
    final trailer = MediaReceiverFeedbackWire.encode(feedback);
    final packet = Uint8List(legacyBody.length + trailer.length)
      ..setAll(0, legacyBody)
      ..setAll(legacyBody.length, trailer);

    final decoded = MediaReceiverFeedbackWire.decode(packet, legacyBody.length);
    expect(decoded?.staleDrops, 6);
    expect(packet.sublist(0, legacyBody.length), legacyBody);
  });
}
