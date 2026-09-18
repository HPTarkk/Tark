import 'package:flutter_test/flutter_test.dart';
import 'package:tark/feature/walkie/domain/service/in_room_invite_policy.dart';

void main() {
  const policy = InRoomInvitePolicy();

  test('ordinary members never receive the host hotspot credential option', () {
    final options = policy.options(
      const InRoomInviteContext(
        isTransportHost: false,
        hasRoomQr: true,
        hasRoomCode: true,
        hasHotspotCredentials: true,
        hasGuestLink: false,
      ),
    );

    expect(
      options.map((option) => option.kind),
      isNot(contains(InRoomInviteKind.hotspotWifi)),
    );
    expect(
      options.map((option) => option.kind),
      contains(InRoomInviteKind.roomQr),
    );
    expect(
      options.map((option) => option.kind),
      contains(InRoomInviteKind.roomCode),
    );
  });

  test('host receives hotspot Wi-Fi invite when fresh credentials exist', () {
    final options = policy.options(
      const InRoomInviteContext(
        isTransportHost: true,
        hasRoomQr: true,
        hasRoomCode: false,
        hasHotspotCredentials: true,
        hasGuestLink: false,
      ),
    );

    final hotspot = options.singleWhere(
      (option) => option.kind == InRoomInviteKind.hotspotWifi,
    );
    expect(hotspot.enabled, isTrue);
    expect(hotspot.reason, isNull);
  });

  test(
    'hotspot recovery disables stale network QR but keeps room invite live',
    () {
      final options = policy.options(
        const InRoomInviteContext(
          isTransportHost: true,
          hasRoomQr: true,
          hasRoomCode: true,
          hasHotspotCredentials: true,
          hasGuestLink: false,
          isRecovering: true,
        ),
      );

      final hotspot = options.singleWhere(
        (option) => option.kind == InRoomInviteKind.hotspotWifi,
      );
      final roomQr = options.singleWhere(
        (option) => option.kind == InRoomInviteKind.roomQr,
      );

      expect(hotspot.enabled, isFalse);
      expect(hotspot.reason, 'hotspot_recovering');
      expect(roomQr.enabled, isTrue);
    },
  );

  test(
    'guest-capable room exposes guest link and share without hotspot data',
    () {
      final options = policy.options(
        const InRoomInviteContext(
          isTransportHost: false,
          hasRoomQr: false,
          hasRoomCode: false,
          hasHotspotCredentials: false,
          hasGuestLink: true,
        ),
      );

      expect(options.map((option) => option.kind), [
        InRoomInviteKind.share,
        InRoomInviteKind.guestLink,
      ]);
    },
  );

  test('Bluetooth-only room with no canonical invite data exposes nothing', () {
    final options = policy.options(
      const InRoomInviteContext(
        isTransportHost: false,
        hasRoomQr: false,
        hasRoomCode: false,
        hasHotspotCredentials: false,
        hasGuestLink: false,
      ),
    );

    expect(options, isEmpty);
  });
}
