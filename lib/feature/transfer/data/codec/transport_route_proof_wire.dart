import 'dart:convert';
import 'dart:typed_data';

abstract final class TransportRouteProofWire {
  static const marker = 0x52;
  static const version = 1;
  static const headerLength = 4;
  static const maxProofBytes = 2048;

  static Uint8List encode(String encodedProof) {
    final bytes = utf8.encode(encodedProof);
    if (bytes.isEmpty || bytes.length > maxProofBytes) {
      throw const FormatException('transport route proof size');
    }
    final output = Uint8List(headerLength + bytes.length);
    output[0] = marker;
    output[1] = version;
    ByteData.sublistView(output).setUint16(2, bytes.length, Endian.little);
    output.setRange(headerLength, output.length, bytes);
    return output;
  }

  static String? decode(Uint8List bytes, int offset) {
    if (offset < 0 || bytes.length - offset < headerLength) return null;
    if (bytes[offset] != marker || bytes[offset + 1] != version) return null;
    final length = ByteData.sublistView(
      bytes,
    ).getUint16(offset + 2, Endian.little);
    if (length == 0 || length > maxProofBytes) return null;
    final start = offset + headerLength;
    final end = start + length;
    if (end != bytes.length) return null;
    try {
      return utf8.decode(bytes.sublist(start, end), allowMalformed: false);
    } catch (_) {
      return null;
    }
  }
}
