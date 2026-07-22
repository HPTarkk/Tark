import 'package:flutter_test/flutter_test.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:tark/feature/transfer/domain/entity/hotspot_credentials.dart';

/// Guards the trade behind the branded hotspot QR (see [GlowingQrCard]).
///
/// Stamping the logo in the middle destroys part of the code, so that QR runs
/// at error-correction level Q. Q needs more modules for the same payload, and
/// modules that get too small stop resolving on a camera pointed at another
/// phone's screen. None of that is visible at a glance, so it's pinned here: if
/// a longer SSID or an extra QR field ever pushes the version up, this fails
/// instead of the code quietly becoming hard to scan in the field.
///
/// Measured for reference, at the 216px the host screen renders: the unbranded
/// level-L code is 6.55px per module for a typical payload; branded Q is
/// 5.84px, and 4.80px on the long-SSID case below. (H — the usual choice for
/// logo QRs, sized for marks 4x bigger than ours — would drop that to 4.08.)
void main() {
  // Widget-side constants this test is asserting against.
  const displaySize = 216.0; // GlowingQrCard size on the host screen
  const logoFraction = 0.24; // _BrandMark width as a fraction of the QR

  /// Below roughly this, modules stop being reliable to scan off a phone
  /// screen at arm's length.
  const minModulePx = 4.5;

  int moduleCountOf(String payload) {
    final result = QrValidator.validate(
      data: payload,
      version: QrVersions.auto,
      errorCorrectionLevel: QrErrorCorrectLevel.Q,
    );
    expect(
      result.status,
      QrValidationStatus.valid,
      reason: 'payload does not encode at level Q: ${result.error}',
    );
    return result.qrCode!.moduleCount;
  }

  test('a typical local-only hotspot payload stays comfortably scannable', () {
    // What Android actually generates: AndroidShare_ + 4 digits, and an
    // 8-to-12 character passphrase.
    const creds = HotspotCredentials(
      ssid: 'AndroidShare_2841',
      passphrase: 'qwer1234asdf',
    );
    final modulePx = displaySize / moduleCountOf(creds.wifiQrPayload);
    expect(modulePx, greaterThan(minModulePx));
  });

  test('an unusually long SSID still clears the bar', () {
    // OEMs don't all follow AOSP's naming; leave room before the version jump
    // costs us scannability.
    const creds = HotspotCredentials(
      ssid: 'SomeVendorVeryLongHotspotName_92841',
      passphrase: 'correcthorsebatterystaple',
      security: 'SAE',
    );
    final modulePx = displaySize / moduleCountOf(creds.wifiQrPayload);
    expect(modulePx, greaterThan(minModulePx));
  });

  test('the logo covers far less than level Q can recover', () {
    // Q recovers ~25% of the code. The mark is a centred square, so what it
    // costs is its area, not its width — the margin is much wider than the
    // 24% figure suggests. Keep roughly a 2x cushion: damage runs a little
    // ahead of raw area because a codeword clipped at the edge is lost whole.
    const coveredArea = logoFraction * logoFraction;
    expect(coveredArea, lessThan(0.125));
  });
}
