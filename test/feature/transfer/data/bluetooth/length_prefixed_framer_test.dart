import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:tark/feature/transfer/data/bluetooth/length_prefixed_framer.dart';

void main() {
  test('reassembles a length-prefixed frame across partial reads', () {
    final payload = Uint8List.fromList([1, 2, 3, 4]);
    final framed = frameMessage(payload);
    final framer = FrameReassembler();

    expect(framer.addBytes(Uint8List.sublistView(framed, 0, 3)), isEmpty);
    final messages = framer.addBytes(Uint8List.sublistView(framed, 3));

    expect(messages, hasLength(1));
    expect(messages.single, payload);
  });

  test('oversized inbound frame is rejected and buffer is reset', () {
    final framer = FrameReassembler(maxFrameLength: 8);
    final header = ByteData(4)..setUint32(0, 4096, Endian.little);

    expect(
      () => framer.addBytes(header.buffer.asUint8List()),
      throwsFormatException,
    );

    final valid = Uint8List.fromList([9, 8, 7]);
    final messages = framer.addBytes(frameMessage(valid));
    expect(messages, hasLength(1));
    expect(messages.single, valid);
  });
}
