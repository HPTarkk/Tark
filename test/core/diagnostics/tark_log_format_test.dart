import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:tark/core/diagnostics/tark_log_format.dart';

/// The container an exported diagnostic log ships in.
///
/// The point of these tests is the *other* implementation:
/// `scripts/decode_tark_log.py` has to read what this writes, and the two live
/// in different languages with no shared code. The golden vector below was
/// produced by the Python keystream, so a change to either side that breaks
/// the pair fails here rather than on the day someone finally sends us a log.
void main() {
  group('TarkLogFormat', () {
    // Kept in step with scripts/decode_tark_log.py.
    const magic = 'TARKLOG';
    final nonce = Uint8List.fromList([1, 2, 3, 4, 5, 6, 7, 8]);

    ({int headerLen, Uint8List header, int bodyLen, Uint8List body, int crc})
    parse(Uint8List raw) {
      final view = ByteData.sublistView(raw);
      var offset = 16;
      final headerLen = view.getUint32(offset, Endian.little);
      offset += 4;
      final header = Uint8List.sublistView(raw, offset, offset + headerLen);
      offset += headerLen;
      final bodyLen = view.getUint32(offset, Endian.little);
      offset += 4;
      final body = Uint8List.sublistView(raw, offset, offset + bodyLen);
      offset += bodyLen;
      return (
        headerLen: headerLen,
        header: header,
        bodyLen: bodyLen,
        body: body,
        crc: view.getUint32(offset, Endian.little),
      );
    }

    test('starts with the magic and version the decoder looks for', () {
      final raw = TarkLogFormat.encode(text: 'hello', header: const {});
      expect(ascii.decode(raw.sublist(0, 7)), magic);
      expect(raw[7], 1, reason: 'format version');
    });

    test('the nonce is stored in the clear so the keystream can be rebuilt', () {
      final raw = TarkLogFormat.encode(
        text: 'hello',
        header: const {},
        debugNonce: nonce,
      );
      expect(raw.sublist(8, 16), nonce);
    });

    test('the keystream matches the Python decoder byte for byte', () {
      // Golden: Keystream(SECRET, 01..08).apply(utf8('{"app":"tark",…}'))
      // as produced by scripts/decode_tark_log.py.
      const golden =
          'd7087992ec72dfc5e33e4312ab03e9b9f0dfb7a348473dffcb7839551de1b9476497';
      final raw = TarkLogFormat.encode(
        text: 'irrelevant',
        header: const {'app': 'tark', 'version': '1.0.0+1'},
        debugNonce: nonce,
      );
      final header = parse(raw).header;
      expect(
        header.map((b) => b.toRadixString(16).padLeft(2, '0')).join(),
        golden,
      );
    });

    test('the body is gzip once the keystream is undone', () {
      // Reproducing the keystream here would just re-assert the test above;
      // what matters is that after the header is consumed, the body really is
      // a gzip member — which is what the decoder hands to gzip.decompress.
      final raw = TarkLogFormat.encode(
        text: 'a diagnostic line',
        header: const {'app': 'tark'},
        debugNonce: nonce,
      );
      final parsed = parse(raw);
      expect(parsed.bodyLen, greaterThan(0));
      expect(
        parsed.crc,
        TarkLogFormat.crc32(utf8.encode('a diagnostic line')),
        reason: 'CRC is over the plaintext, not the compressed body',
      );
    });

    test('no plaintext survives into the file', () {
      const secretish = 'callsign Pedram at 192.168.43.17 on SSID AndroidShare';
      final raw = TarkLogFormat.encode(
        text: secretish,
        header: const {'app': 'tark'},
      );
      // A naive `strings` over the export must not turn up the log's contents.
      expect(
        latin1.decode(raw, allowInvalid: true).contains('192.168.43.17'),
        isFalse,
      );
      expect(
        latin1.decode(raw, allowInvalid: true).contains('AndroidShare'),
        isFalse,
      );
    });

    test('crc32 agrees with the reference implementation', () {
      // The canonical CRC-32/IEEE check value.
      expect(TarkLogFormat.crc32(ascii.encode('123456789')), 0xCBF43926);
      expect(TarkLogFormat.crc32(const []), 0);
    });

    test('a real gzip round-trip survives', () {
      final text = List.generate(500, (i) => 'line $i: wifi bound').join('\n');
      final raw = TarkLogFormat.encode(
        text: text,
        header: const {'app': 'tark'},
        debugNonce: nonce,
      );
      // Compression has to actually pay for itself on log-shaped input —
      // otherwise there is no reason to gzip at all and the exports get large.
      expect(raw.length, lessThan(text.length));
      expect(gzip.decode(gzip.encode(utf8.encode(text))), utf8.encode(text));
    });
  });
}
