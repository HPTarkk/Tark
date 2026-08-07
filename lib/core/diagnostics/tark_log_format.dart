import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

/// The `.tarklog` container: how an exported diagnostic log is packed so it
/// survives a trip through a chat app and can still be read back by us.
///
/// ## Why it isn't a plain text file
///
/// A log worth having names the things that make a session diagnosable: the
/// user's callsign, everyone's LAN addresses, the hotspot SSID, device ids.
/// A user sending that over WhatsApp to get help should not be handing the
/// group chat a readable dossier, and — just as important — should not be
/// tempted to "tidy up" the file before sending it, which is how the one line
/// that mattered goes missing.
///
/// So the payload is gzipped and run through a keystream. This is **not
/// encryption and must never be described as such**: the key is a constant in
/// a shipped app, so anyone willing to read this source can read the log. It
/// is exactly what it looks like — a format only we have the tool for, which
/// keeps the file opaque in transit and intact on arrival.
///
/// ## Layout (integers little-endian)
///
/// ```
///   0   8   magic "TARKLOG" + format version byte
///   8   8   nonce (random per export, in the clear — it seeds the keystream)
///  16   4   header length H
///  20   H   header:  keystream(JSON, UTF-8)
///  ..   4   body length B
///  ..   B   body:    keystream(gzip(UTF-8 log text))
///  ..   4   CRC32 of the *plaintext* log text
/// ```
///
/// The header stays small and structured (app version, platform, when) so the
/// decoder can print a useful banner before it touches the body, and so a
/// truncated file still says which build it came from.
///
/// Decode with `scripts/decode_tark_log.py` — keep the two in step.
abstract final class TarkLogFormat {
  /// File extension, and the thing to grep for in a downloads folder.
  static const extension = 'tarklog';

  static const _magic = 'TARKLOG';
  static const _version = 1;

  /// Keystream seed constant. Shared verbatim with the decoder script; see the
  /// class doc for why this being public knowledge is fine.
  static const _secret = 0x5441524B4C4F4731; // "TARKLOG1"

  /// Packs [text] with [header] into the container above.
  ///
  /// [debugNonce] is for the cross-language test only: with the nonce pinned,
  /// the keystream is deterministic and the Dart encoder can be checked
  /// against bytes the Python decoder produces. Nothing in the app passes it,
  /// and nothing should — a fixed nonce in production would put every export
  /// on one keystream. (No `@visibleForTesting`: that annotation cannot be
  /// applied to a parameter.)
  static Uint8List encode({
    required String text,
    required Map<String, Object?> header,
    Uint8List? debugNonce,
  }) {
    final plain = utf8.encode(text);
    final headerBytes = utf8.encode(jsonEncode(header));
    final bodyBytes = gzip.encode(plain);

    final nonce = debugNonce ?? _randomNonce();
    // One continuous keystream across header then body: the decoder consumes
    // them in the same order, so no per-section position bookkeeping can drift
    // between the two implementations.
    final stream = _Keystream(_secret, nonce);
    final obfHeader = stream.apply(headerBytes);
    final obfBody = stream.apply(bodyBytes);

    final out = BytesBuilder(copy: false);
    out.add(ascii.encode(_magic));
    out.addByte(_version);
    out.add(nonce);
    out.add(_uint32(obfHeader.length));
    out.add(obfHeader);
    out.add(_uint32(obfBody.length));
    out.add(obfBody);
    out.add(_uint32(crc32(plain)));
    return out.toBytes();
  }

  static Uint8List _uint32(int value) =>
      (ByteData(4)..setUint32(0, value, Endian.little)).buffer.asUint8List();

  static Uint8List _randomNonce() {
    final random = Random.secure();
    return Uint8List.fromList(
      List<int>.generate(8, (_) => random.nextInt(256)),
    );
  }

  /// CRC-32 (IEEE), so the decoder can say "this file arrived intact" rather
  /// than printing a plausible-looking half of a log. Hand-rolled to keep this
  /// file dependency-free — it is the one piece the decoder script has to
  /// reimplement, and a 20-line table is easier to keep honest than a package
  /// version.
  static int crc32(List<int> bytes) {
    var crc = 0xFFFFFFFF;
    for (final byte in bytes) {
      crc ^= byte & 0xFF;
      for (var bit = 0; bit < 8; bit++) {
        crc = (crc & 1) != 0 ? (crc >> 1) ^ 0xEDB88320 : crc >> 1;
      }
    }
    return (crc ^ 0xFFFFFFFF) & 0xFFFFFFFF;
  }
}

/// xorshift64* over the seed mixed with the export's nonce, one byte drawn per
/// output byte. Deliberately trivial: it has to be reimplementable in a few
/// lines of Python without pulling in a crypto library, because the decoder is
/// a script someone runs once on a phone log, not a product.
class _Keystream {
  _Keystream(int secret, List<int> nonce) {
    var seed = secret;
    for (final byte in nonce) {
      seed = (seed ^ byte) * 0x100000001B3;
    }
    // A zero state is a fixed point of xorshift — impossible in practice here,
    // but the guard costs one comparison and removes the "produces all zeros,
    // i.e. no obfuscation at all" failure mode entirely.
    _state = seed == 0 ? 0x2545F4914F6CDD1D : seed;
  }

  late int _state;

  int _next() {
    var x = _state;
    x ^= x >>> 12;
    x ^= x << 25;
    x ^= x >>> 27;
    _state = x;
    return (x * 0x2545F4914F6CDD1D) >>> 24;
  }

  Uint8List apply(List<int> bytes) {
    final out = Uint8List(bytes.length);
    for (var i = 0; i < bytes.length; i++) {
      out[i] = (bytes[i] ^ (_next() & 0xFF)) & 0xFF;
    }
    return out;
  }
}
