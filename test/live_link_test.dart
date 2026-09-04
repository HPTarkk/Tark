import 'package:flutter_test/flutter_test.dart';
import 'package:tark/feature/transfer/domain/entity/live_link.dart';
import 'package:tark/feature/transfer/domain/entity/transfer_mode.dart';

/// The half of the link gate that can be decided without a radio.
///
/// The other half — reading the radios — is a platform channel and a
/// `NetworkInterface` list, and is not what goes wrong here. What goes wrong
/// is the arithmetic on top of it: which link a session should run over when
/// two are up, and whether finding one is allowed to move the transport the
/// user chose.
void main() {
  const nothing = LiveLinkSnapshot.none;
  const wifiOnly = LiveLinkSnapshot(
    wifi: true,
    hostingHotspot: false,
    bluetooth: false,
  );
  const bluetoothOnly = LiveLinkSnapshot(
    wifi: false,
    hostingHotspot: false,
    bluetooth: true,
  );
  const hostingOnly = LiveLinkSnapshot(
    wifi: false,
    hostingHotspot: true,
    bluetooth: false,
  );

  group('a room may not go live over nothing', () {
    test('no radio up resolves to no link, on every transport', () {
      for (final mode in TransferMode.values) {
        expect(nothing.resolve(mode), LiveLink.none, reason: mode.key);
        expect(nothing.resolve(mode).isUp, isFalse, reason: mode.key);
      }
      expect(nothing.isUp, isFalse);
    });

    test('any one radio up is a link', () {
      expect(wifiOnly.isUp, isTrue);
      expect(bluetoothOnly.isUp, isTrue);
      expect(hostingOnly.isUp, isTrue);
    });
  });

  group('the transport in effect picks the link, not the other way round', () {
    const both = LiveLinkSnapshot(
      wifi: true,
      hostingHotspot: false,
      bluetooth: true,
    );

    test('a paired phone in a house with Wi-Fi stays on Bluetooth', () {
      expect(both.resolve(TransferMode.bluetooth), LiveLink.bluetooth);
      expect(
        LiveLink.bluetooth.modeFor(TransferMode.bluetooth),
        TransferMode.bluetooth,
      );
    });

    test('the same phone set to Wi-Fi stays on Wi-Fi', () {
      expect(both.resolve(TransferMode.wifi), LiveLink.wifi);
      expect(LiveLink.wifi.modeFor(TransferMode.wifi), TransferMode.wifi);
    });

    test('hosting outranks being on a network when neither fits', () {
      const concurrent = LiveLinkSnapshot(
        wifi: false,
        hostingHotspot: true,
        bluetooth: true,
      );
      // Bluetooth is up and so is our own access point; the transport is set
      // to plain Wi-Fi, which neither of them carries. Hosting wins because
      // raising an access point is the more deliberate of the two acts.
      expect(concurrent.resolve(TransferMode.wifi), LiveLink.hotspotHost);
    });
  });

  group('the transport moves only when it has to', () {
    test('Wi-Fi and hotspot are both carried by an association', () {
      expect(LiveLink.wifi.carries(TransferMode.wifi), isTrue);
      expect(LiveLink.wifi.carries(TransferMode.hotspot), isTrue);
      // A joined hotspot is not distinguishable from a router here, and the
      // mode is the only thing that remembers which end of a bridge this
      // phone is. Re-deriving it would lose that.
      expect(LiveLink.wifi.modeFor(TransferMode.hotspot), TransferMode.hotspot);
      expect(LiveLink.wifi.modeFor(TransferMode.wifi), TransferMode.wifi);
    });

    test('a device holding an access point up is on the hotspot transport', () {
      expect(LiveLink.hotspotHost.carries(TransferMode.wifi), isFalse);
      expect(
        LiveLink.hotspotHost.modeFor(TransferMode.wifi),
        TransferMode.hotspot,
      );
    });

    test('a stale transport with no link under it is replaced', () {
      // Set to Bluetooth from last week, standing on a Wi-Fi network today.
      expect(wifiOnly.resolve(TransferMode.bluetooth), LiveLink.wifi);
      expect(LiveLink.wifi.modeFor(TransferMode.bluetooth), TransferMode.wifi);
      // And the mirror: set to Wi-Fi, paired over Bluetooth.
      expect(bluetoothOnly.resolve(TransferMode.wifi), LiveLink.bluetooth);
      expect(
        LiveLink.bluetooth.modeFor(TransferMode.wifi),
        TransferMode.bluetooth,
      );
    });

    test('a browser guest keeps its transport over any IP link', () {
      // The guest page only navigates once a browser is actually attached, so
      // moving the Room onto the Wi-Fi repository here would drop the one
      // peer the session has.
      expect(LiveLink.wifi.carries(TransferMode.guest), isTrue);
      expect(LiveLink.hotspotHost.carries(TransferMode.guest), isTrue);
      expect(wifiOnly.resolve(TransferMode.guest), LiveLink.wifi);
      expect(LiveLink.wifi.modeFor(TransferMode.guest), TransferMode.guest);
      expect(hostingOnly.resolve(TransferMode.guest), LiveLink.hotspotHost);
      expect(
        LiveLink.hotspotHost.modeFor(TransferMode.guest),
        TransferMode.guest,
      );
      // Bluetooth cannot carry a WebRTC data channel, so there it does move.
      expect(LiveLink.bluetooth.carries(TransferMode.guest), isFalse);
      expect(
        LiveLink.bluetooth.modeFor(TransferMode.guest),
        TransferMode.bluetooth,
      );
    });

    test('no link leaves the transport exactly where it was', () {
      for (final mode in TransferMode.values) {
        expect(LiveLink.none.modeFor(mode), mode, reason: mode.key);
      }
    });
  });
}
