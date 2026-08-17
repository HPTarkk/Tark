import 'package:flutter_test/flutter_test.dart';
import 'package:tark/feature/transfer/domain/service/host_subnet_filter.dart';

/// Keeping a hotspot host on its own AP.
///
/// The field failure: host on home Wi-Fi *and* hosting, joiner on the AP, both
/// entered the channel, neither ever heard the other — two halves of one
/// session on two subnets, with both phones reporting an empty room and every
/// other diagnostic reading healthy.
void main() {
  const ap = '192.168.43';
  const home = '192.168.1';

  test('a host drops the subnet it is only a client of', () {
    expect(
      HostSubnetFilter.apply(
        subnets: const [ap, home],
        clientIp: '192.168.1.37',
        isHost: true,
      ),
      const [ap],
    );
  });

  test('a joiner is left alone — it has no AP of its own to prefer', () {
    expect(
      HostSubnetFilter.apply(
        subnets: const [ap, home],
        clientIp: '192.168.43.22',
        isHost: false,
      ),
      const [ap, home],
    );
  });

  test('a host with no client connection keeps everything', () {
    // Wi-Fi off, or the single-radio case where the framework already dropped
    // the client side when the AP came up. Nothing to exclude.
    expect(
      HostSubnetFilter.apply(
        subnets: const [ap],
        clientIp: null,
        isHost: true,
      ),
      const [ap],
    );
  });

  test('never filters down to nothing', () {
    // The race that would otherwise kill a session outright: on a single-radio
    // phone the client connection is torn down as the AP comes up, and a stale
    // read can name the only subnet we can currently see. Excluding it would
    // leave the host unable to reach anyone at all — strictly worse than the
    // unfiltered behaviour.
    expect(
      HostSubnetFilter.apply(
        subnets: const [home],
        clientIp: '192.168.1.37',
        isHost: true,
      ),
      const [home],
    );
  });

  test('a malformed client address is ignored rather than guessed at', () {
    for (final bad in ['', 'unknown', '192.168.1', '1.2.3.4.5', 'a.b.c.d']) {
      expect(
        HostSubnetFilter.apply(
          subnets: const [ap, home],
          clientIp: bad,
          isHost: true,
        ),
        const [ap, home],
        reason: 'clientIp "$bad" must not exclude anything',
      );
    }
  });

  test('excludes by /24, not by exact address', () {
    // The host sees its own AP address; the client address it is told about is
    // a different host on that subnet. Matching whole addresses would never
    // fire.
    expect(HostSubnetFilter.prefixOf('192.168.1.37'), home);
    expect(HostSubnetFilter.prefixOf('10.0.0.5'), '10.0.0');
  });

  test('a host on several client networks drops only the named one', () {
    // Cellular or a USB tether can add a third private interface. Only the
    // Wi-Fi client subnet is known to be wrong; the rest keep their existing
    // treatment rather than being guessed about.
    expect(
      HostSubnetFilter.apply(
        subnets: const [ap, home, '10.0.0'],
        clientIp: '192.168.1.37',
        isHost: true,
      ),
      const [ap, '10.0.0'],
    );
  });
}
