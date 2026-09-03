import 'dart:convert';
import 'dart:typed_data';

/// Optional control-packet record carrying a signed "move to this network"
/// instruction.
///
/// Appended to ping and pong the same additive way every other trailer here
/// is: a build that predates it stops reading at the record before, so the two
/// generations of the app share a channel rather than splitting it.
///
/// Unlike [TransportRouteProofWire] this does **not** have to be the last
/// record in the packet — [decode] reads its own length and [encodedLengthAt]
/// lets the caller step past it — because on a pong the route proof still owns
/// the tail. Ordering matters more than it looks: the route proof's decoder
/// asserts it runs to the end of the datagram, so anything appended after it
/// would silently invalidate it.
abstract final class CarrierHandoverWire {
  static const marker = 0x48; // 'H' for handover.
  static const version = 1;
  static const headerLength = 4;

  /// Comfortably above a real announcement (an Ed25519 signature, a member
  /// certificate, an SSID and a passphrase — roughly 700 bytes encoded) and
  /// far below anything that would push a control datagram past a safe MTU.
  static const maxPayloadBytes = 2048;

  static Uint8List encode(String encodedHandover) {
    final bytes = utf8.encode(encodedHandover);
    if (bytes.isEmpty || bytes.length > maxPayloadBytes) {
      throw const FormatException('carrier handover record size');
    }
    final output = Uint8List(headerLength + bytes.length);
    output[0] = marker;
    output[1] = version;
    ByteData.sublistView(output).setUint16(2, bytes.length, Endian.little);
    output.setRange(headerLength, output.length, bytes);
    return output;
  }

  static String? decode(Uint8List bytes, int offset) {
    final length = _payloadLength(bytes, offset);
    if (length == null) return null;
    final start = offset + headerLength;
    final end = start + length;
    if (end > bytes.length) return null;
    try {
      return utf8.decode(bytes.sublist(start, end), allowMalformed: false);
    } catch (_) {
      return null;
    }
  }

  /// Total bytes this record occupies at [offset], or zero if there is no
  /// well-formed record there — so a caller can advance unconditionally.
  static int encodedLengthAt(Uint8List bytes, int offset) {
    final length = _payloadLength(bytes, offset);
    if (length == null) return 0;
    final total = headerLength + length;
    return offset + total > bytes.length ? 0 : total;
  }

  static int? _payloadLength(Uint8List bytes, int offset) {
    if (offset < 0 || bytes.length - offset < headerLength) return null;
    if (bytes[offset] != marker || bytes[offset + 1] != version) return null;
    final length = ByteData.sublistView(
      bytes,
    ).getUint16(offset + 2, Endian.little);
    if (length == 0 || length > maxPayloadBytes) return null;
    return length;
  }
}
