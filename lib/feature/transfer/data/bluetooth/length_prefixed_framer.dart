import 'dart:typed_data';

/// RFCOMM (Bluetooth Classic) is a raw byte stream with no message
/// boundaries, unlike UDP which preserves datagram boundaries automatically.
/// This adds a simple 4-byte little-endian length prefix per message so the
/// receiving side can split the stream back into discrete [WakiPacketCodec]
/// messages.
Uint8List frameMessage(Uint8List payload) {
  final builder = BytesBuilder(copy: false);
  builder.add((ByteData(4)..setUint32(0, payload.length, Endian.little))
      .buffer
      .asUint8List());
  builder.add(payload);
  return builder.toBytes();
}

/// Buffers partial reads from a Bluetooth Classic socket and yields complete
/// length-prefixed messages as they become available.
class FrameReassembler {
  final BytesBuilder _buffer = BytesBuilder(copy: true);

  List<Uint8List> addBytes(Uint8List chunk) {
    _buffer.add(chunk);
    final messages = <Uint8List>[];

    var pending = _buffer.toBytes();
    while (pending.length >= 4) {
      final length =
          ByteData.sublistView(pending, 0, 4).getUint32(0, Endian.little);
      if (pending.length < 4 + length) break;
      messages.add(pending.sublist(4, 4 + length));
      pending = pending.sublist(4 + length);
    }

    _buffer.clear();
    if (pending.isNotEmpty) _buffer.add(pending);

    return messages;
  }

  /// Discards any partially-buffered message (e.g. on reconnect).
  void reset() => _buffer.clear();
}
