import 'package:flutter_test/flutter_test.dart';
import 'package:tark/feature/transfer/domain/entity/hotspot_credentials.dart';

void main() {
  group('one-scan Room hotspot payload', () {
    test('round-trips network credentials and opaque Room invite', () {
      const credentials = HotspotCredentials(
        ssid: 'Tark;Ride:01',
        passphrase: r'p;ass:word\x',
        security: 'WPA',
      );
      const invite = 'tark-room:AbC_def-0123';

      final raw = credentials.qrPayload(roomInvite: invite);
      final scanned = ScannedCode.parse(raw);

      expect(scanned, isNotNull);
      expect(scanned!.credentials, credentials);
      expect(scanned.roomInvite, invite);
      expect(raw, startsWith('WIFI:'));
      expect(raw, contains('TARKROOM1:'));
    });

    test('ordinary Wi-Fi QR stays backward compatible without Room data', () {
      const credentials = HotspotCredentials(
        ssid: 'Tark-Ride',
        passphrase: '12345678',
      );

      final raw = credentials.wifiQrPayload;
      final scanned = ScannedCode.parse(raw);

      expect(scanned, isNotNull);
      expect(scanned!.credentials, credentials);
      expect(scanned.roomInvite, isNull);
    });

    test('empty Room invite is not emitted as another join method', () {
      const credentials = HotspotCredentials(
        ssid: 'Tark-Ride',
        passphrase: '12345678',
      );

      final raw = credentials.qrPayload(roomInvite: '   ');
      final scanned = ScannedCode.parse(raw);

      expect(raw, isNot(contains('TARKROOM1:')));
      expect(scanned!.roomInvite, isNull);
    });
  });
}
