import 'package:flutter_test/flutter_test.dart';
import 'package:tark/feature/transfer/domain/service/network_interface_policy.dart';

void main() {
  const policy = NetworkInterfacePolicy();

  NetworkInterfaceCandidate candidate(
    String name, {
    bool loopback = false,
    bool linkLocal = false,
    bool vpn = false,
  }) => NetworkInterfaceCandidate(
    name: name,
    isLoopback: loopback,
    isLinkLocal: linkLocal,
    isVpnLike: vpn,
  );

  test('wlan + VPN keeps only the selected wlan interface', () {
    final selected = policy.select(
      candidates: [candidate('wlan0'), candidate('tun0', vpn: true)],
      selectedInterfaceName: 'wlan0',
    );

    expect(selected.map((entry) => entry.name), ['wlan0']);
  });

  test('hotspot + tunnel keeps selected hotspot-facing interface', () {
    final selected = policy.select(
      candidates: [
        candidate('wlan0'),
        candidate('ap0'),
        candidate('wg0', vpn: true),
      ],
      selectedInterfaceName: 'ap0',
    );

    expect(selected.map((entry) => entry.name), ['ap0']);
  });

  test('loopback and link-local candidates are never discovery targets', () {
    final selected = policy.select(
      candidates: [
        candidate('lo', loopback: true),
        candidate('wlan0'),
        candidate('ll0', linkLocal: true),
      ],
    );

    expect(selected.map((entry) => entry.name), ['wlan0']);
  });

  test('missing native metadata falls back to safe non-tunnel candidates', () {
    final selected = policy.select(
      candidates: [
        candidate('wlan0'),
        candidate('ap0'),
        candidate('tun0', vpn: true),
      ],
      selectedInterfaceName: null,
    );

    expect(selected.map((entry) => entry.name), ['wlan0', 'ap0']);
  });

  test('native interface leading Dart enumeration falls back temporarily', () {
    final selected = policy.select(
      candidates: [candidate('wlan0')],
      selectedInterfaceName: 'ap0',
    );

    expect(selected.map((entry) => entry.name), ['wlan0']);
  });

  test('a VPN-selected default never causes its tunnel to be broadcast', () {
    final selected = policy.select(
      candidates: [candidate('wlan0'), candidate('tun0', vpn: true)],
      selectedInterfaceName: 'tun0',
      selectedNetworkIsVpn: true,
    );

    expect(selected.map((entry) => entry.name), ['wlan0']);
  });
}
