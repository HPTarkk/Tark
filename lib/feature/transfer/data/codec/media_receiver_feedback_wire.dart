import 'dart:typed_data';

import '../../domain/entity/media_receiver_feedback.dart';

/// Additive, mixed-version-safe wire trailer for Shared Music receiver health.
///
/// This payload is appended after an existing ping/pong body. Older decoders
/// already stop after the fields they know and therefore ignore these bytes.
/// New decoders require the complete known version before accepting it, so a
/// clipped/unknown trailer becomes null (unconfirmed) rather than fabricated
/// clean receiver evidence.
abstract final class MediaReceiverFeedbackWire {
  static const version = 1;
  static const fieldCount = 9;
  static const encodedLength = 1 + fieldCount * 2;

  static Uint8List encode(MediaReceiverFeedback feedback) {
    final bytes = Uint8List(encodedLength);
    final data = ByteData.sublistView(bytes);
    data.setUint8(0, version);
    final values = [
      feedback.queuedMs,
      feedback.underruns,
      feedback.outputStarvations,
      feedback.trims,
      feedback.overflowDrops,
      feedback.staleDrops,
      feedback.duplicateDrops,
      feedback.resyncs,
      feedback.concealedMs,
    ];
    for (var i = 0; i < values.length; i++) {
      data.setUint16(1 + i * 2, _bounded(values[i]), Endian.little);
    }
    return bytes;
  }

  static MediaReceiverFeedback? decode(Uint8List bytes, int offset) {
    if (offset < 0 || bytes.length < offset + encodedLength) return null;
    final data = ByteData.sublistView(bytes);
    if (data.getUint8(offset) != version) return null;

    int value(int index) =>
        data.getUint16(offset + 1 + index * 2, Endian.little);

    return MediaReceiverFeedback(
      queuedMs: value(0),
      underruns: value(1),
      outputStarvations: value(2),
      trims: value(3),
      overflowDrops: value(4),
      staleDrops: value(5),
      duplicateDrops: value(6),
      resyncs: value(7),
      concealedMs: value(8),
    );
  }

  static int _bounded(int value) => value.clamp(0, 0xffff);
}
