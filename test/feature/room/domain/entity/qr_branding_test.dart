import 'package:flutter_test/flutter_test.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:tark/feature/room/domain/entity/room.dart';
import 'package:tark/feature/room/domain/entity/room_accepted_join_snapshot.dart';
import 'package:tark/feature/room/domain/entity/room_direct_join_bundle.dart';
import 'package:tark/feature/room/domain/service/room_member_transport_identity.dart';
import 'package:tark/feature/transfer/domain/entity/hotspot_credentials.dart';

/// Guards the trade behind every branded QR (see [GlowingQrCard]).
///
/// Stamping the logo in the middle destroys part of the code, so a branded QR
/// runs at error-correction level Q. Q needs more modules for the same
/// payload, and modules that get too small stop resolving on a camera pointed
/// at another phone's screen. None of that is visible at a glance, so it's
/// pinned here: if a payload ever grows enough to push the version up, this
/// fails instead of the code quietly becoming hard to scan in the field.
///
/// The two codes sit at very different payload sizes and so answer to
/// different bars — the hotspot's ~55 bytes can afford margin the Room
/// invite's ~400 never could.
void main() {
  // Widget-side constants this test is asserting against.
  const logoFraction = 0.24; // _BrandMark width as a fraction of the QR

  int moduleCountOf(String payload, {required int level}) {
    final result = QrValidator.validate(
      data: payload,
      version: QrVersions.auto,
      errorCorrectionLevel: level,
    );
    expect(
      result.status,
      QrValidationStatus.valid,
      reason: 'payload does not encode: ${result.error}',
    );
    return result.qrCode!.moduleCount;
  }

  /// Measured for reference, at the 216px the host screen renders: the
  /// unbranded level-L code is 6.55px per module for a typical payload;
  /// branded Q is 5.84px, and 4.80px on the long-SSID case below. (H — the
  /// usual choice for logo QRs, sized for marks 4x bigger than ours — would
  /// drop that to 4.08.)
  group('hotspot Wi-Fi code', () {
    const displaySize = 216.0; // GlowingQrCard size on the host screen

    /// Below roughly this, modules stop being reliable to scan off a phone
    /// screen at arm's length.
    const minModulePx = 4.5;

    test(
      'a typical local-only hotspot payload stays comfortably scannable',
      () {
        // What Android actually generates: AndroidShare_ + 4 digits, and an
        // 8-to-12 character passphrase.
        const creds = HotspotCredentials(
          ssid: 'AndroidShare_2841',
          passphrase: 'qwer1234asdf',
        );
        final modules = moduleCountOf(
          creds.wifiQrPayload,
          level: QrErrorCorrectLevel.Q,
        );
        expect(displaySize / modules, greaterThan(minModulePx));
      },
    );

    test('an unusually long SSID still clears the bar', () {
      // OEMs don't all follow AOSP's naming; leave room before the version
      // jump costs us scannability.
      const creds = HotspotCredentials(
        ssid: 'SomeVendorVeryLongHotspotName_92841',
        passphrase: 'correcthorsebatterystaple',
        security: 'SAE',
      );
      final modules = moduleCountOf(
        creds.wifiQrPayload,
        level: QrErrorCorrectLevel.Q,
      );
      expect(displaySize / modules, greaterThan(minModulePx));
    });
  });

  /// The Room invite carries an identity, a certificate and a roster, so it is
  /// an order of magnitude larger than the Wi-Fi code and can never reach that
  /// group's bar. What it has to clear instead is the v1 envelope it replaced:
  /// ~1600 characters at level L, which came out at 137 modules — 1.82px each
  /// — and was reported from the field as hard to scan.
  group('Room invite code', () {
    const displaySize = 250.0; // GlowingQrCard size on the invite sheet
    const v1ModulePx = 250.0 / 137;

    test('the common case is branded, and beats v1 with the mark on', () {
      final payload = _invite(members: 2);
      final modules = moduleCountOf(payload, level: QrErrorCorrectLevel.Q);

      expect(
        payload.length,
        lessThanOrEqualTo(RoomDirectJoinBundle.brandableEncodedLength),
      );
      expect(displaySize / modules, greaterThan(v1ModulePx * 1.4));
    });

    test('the largest branded payload still clears the bar', () {
      // The threshold is a byte count the widget can check cheaply; this is
      // what that byte count actually buys once qr_flutter has encoded it.
      final payload =
          'tark-room:'
          '${'A' * (RoomDirectJoinBundle.brandableEncodedLength - 10)}';
      final modules = moduleCountOf(payload, level: QrErrorCorrectLevel.Q);

      expect(modules, lessThanOrEqualTo(97));
      expect(displaySize / modules, greaterThan(2.5));
    });

    test('dropping the mark makes the code easier to scan, not harder', () {
      // The fallback above the threshold has to be an improvement, or the
      // widget would be trading legibility for a logo in the wrong direction.
      final branded = moduleCountOf(
        _invite(members: 3),
        level: QrErrorCorrectLevel.Q,
      );
      final unbranded = moduleCountOf(
        _invite(members: 4),
        level: QrErrorCorrectLevel.L,
      );

      expect(unbranded, lessThan(branded));
    });

    test('a full roster still encodes unbranded, and stays readable', () {
      final payload = _invite(members: RoomAcceptedJoinSnapshot.maxMembers);
      final modules = moduleCountOf(payload, level: QrErrorCorrectLevel.L);

      expect(
        payload.length,
        greaterThan(RoomDirectJoinBundle.brandableEncodedLength),
      );
      expect(displaySize / modules, greaterThan(v1ModulePx * 1.2));
    });
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

/// A realistic invite for a Room of [members], Persian display names and all —
/// the roster is what the payload scales with, so a Latin-only fixture would
/// flatter it.
String _invite({required int members}) {
  const roomId = RoomId('abababababababababababababababab');
  const joinerId = RoomMemberId('222222222222222222222222');
  final joinedAt = DateTime.utc(2026, 9, 2, 12, 30, 15, 250);
  final keyPair = RoomMemberTransportKeyPair(
    privateKey: List<int>.generate(32, (i) => (i * 7 + 3) & 0xff),
    publicKey: List<int>.generate(32, (i) => (i * 7 + 11) & 0xff),
  );
  return RoomDirectJoinBundle(
    memberId: joinerId,
    snapshot: RoomAcceptedJoinSnapshot(
      roomId: roomId,
      roomName: 'رکاب صبح جمعه',
      roomCreatedAt: joinedAt,
      roomUpdatedAt: joinedAt,
      members: [
        for (var index = 0; index < members - 1; index += 1)
          RoomAcceptedJoinMember(
            memberId: RoomMemberId(
              '11111111111111111111111${index.toRadixString(16)}',
            ),
            displayName: 'همراه شماره $index',
            joinedAt: joinedAt,
            kind: RoomMemberKind.member,
          ),
        RoomAcceptedJoinMember(
          memberId: joinerId,
          displayName: 'جای خالی',
          joinedAt: joinedAt,
          kind: RoomMemberKind.member,
        ),
      ],
    ),
    memberKeyPair: keyPair,
    certificate: RoomMemberTransportCertificate(
      roomId: roomId,
      memberId: joinerId,
      memberPublicKey: keyPair.publicKey,
      issuerPublicKey: List<int>.generate(32, (i) => (i * 7 + 29) & 0xff),
      issuerSignature: List<int>.generate(64, (i) => (i * 7 + 47) & 0xff),
    ),
    expiresAt: DateTime.utc(2099),
  ).encode();
}
