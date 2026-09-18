import 'package:flutter_test/flutter_test.dart';
import 'package:tark/feature/transfer/domain/entity/hotspot_credentials.dart';

void main() {
  test('QR payload round-trips through the parser', () {
    const creds = HotspotCredentials(
      ssid: 'AndroidShare_1234',
      passphrase: 'hunter2pass',
    );
    final parsed = HotspotCredentials.fromWifiQr(creds.wifiQrPayload);
    expect(parsed, creds);
  });

  test('separator characters survive the escaping round-trip', () {
    // A LocalOnlyHotspot passphrase is generated, but the spec's separators
    // would silently split the payload if they weren't escaped.
    const creds = HotspotCredentials(
      ssid: r'net;with:odd,chars"and\slash',
      passphrase: r'pa;ss:wo,rd"x\y',
    );
    final parsed = HotspotCredentials.fromWifiQr(creds.wifiQrPayload);
    expect(parsed?.ssid, creds.ssid);
    expect(parsed?.passphrase, creds.passphrase);
  });

  test('security type carries through so the peer can pick WPA2 vs SAE', () {
    const sae = HotspotCredentials(
      ssid: 'wpa3only',
      passphrase: 'secret123',
      security: 'SAE',
    );
    expect(sae.wifiQrPayload, contains('T:SAE;'));
    expect(HotspotCredentials.fromWifiQr(sae.wifiQrPayload)?.security, 'SAE');
  });

  test('a payload without T: is treated as WPA rather than open', () {
    final parsed = HotspotCredentials.fromWifiQr('WIFI:S:plain;P:secret123;;');
    expect(parsed?.security, 'WPA');
    expect(parsed?.passphrase, 'secret123');
  });

  test('non-Wi-Fi and SSID-less payloads are rejected', () {
    expect(HotspotCredentials.fromWifiQr('https://example.com'), isNull);
    expect(HotspotCredentials.fromWifiQr('WIFI:T:WPA;P:secret123;;'), isNull);
    expect(HotspotCredentials.fromWifiQr('WIFI:S:;T:WPA;P:x;;'), isNull);
  });
}
