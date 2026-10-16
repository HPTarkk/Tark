import 'package:flutter_test/flutter_test.dart';
import 'package:tark/feature/room/domain/service/room_hotspot_fallback_detector.dart';

/// 2026-10-15: the hotspot dropped forty seconds into a call and both phones
/// carried on over the house router. The other phone's proofs said so the
/// whole time ("moved from 192.168.43.79 to 192.168.8.107"); nothing listened.
void main() {
  test('proofs that move to another network are a fall back', () {
    final detector = RoomHotspotFallbackDetector()..seed('192.168.43.79');
    expect(detector.observe('192.168.43.79'), isFalse);
    expect(detector.observe('192.168.8.107'), isFalse, reason: 'straggler');
    expect(detector.observe('192.168.8.107'), isTrue);
  });

  test('one straggler between hotspot proofs is not a fall back', () {
    final detector = RoomHotspotFallbackDetector()..seed('192.168.43.79');
    expect(detector.observe('192.168.8.107'), isFalse);
    expect(detector.observe('192.168.43.79'), isFalse);
    expect(detector.observe('192.168.8.107'), isFalse);
  });

  test('another address on the hotspot is the same network', () {
    final detector = RoomHotspotFallbackDetector()..seed('192.168.43.79');
    expect(detector.observe('192.168.43.12'), isFalse);
    expect(detector.observe('192.168.43.12'), isFalse);
  });

  test('without a seed the first proof is the hotspot', () {
    final detector = RoomHotspotFallbackDetector();
    expect(detector.observe('10.1.2.3'), isFalse);
    expect(detector.hotspotRoute, '10.1.2.3');
    expect(detector.observe('10.1.2.4'), isFalse);
  });

  test('a reset forgets the hotspot, as a planned hand-over needs', () {
    final detector = RoomHotspotFallbackDetector()..seed('192.168.43.79');
    expect(detector.observe('192.168.8.107'), isFalse);
    detector.reset();
    expect(detector.observe('192.168.49.5'), isFalse);
    expect(detector.observe('192.168.49.5'), isFalse);
  });

  test('empty or missing routes say nothing', () {
    final detector = RoomHotspotFallbackDetector()..seed('192.168.43.79');
    expect(detector.observe(null), isFalse);
    expect(detector.observe(''), isFalse);
    expect(detector.observe(''), isFalse);
  });

  test('non-IPv4 routes compare whole', () {
    expect(
      RoomHotspotFallbackDetector.sameNetwork('fe80::1', 'fe80::1'),
      isTrue,
    );
    expect(
      RoomHotspotFallbackDetector.sameNetwork('fe80::1', 'fe80::2'),
      isFalse,
    );
  });

  test('tells a route on the hotspot from one on the router', () {
    final detector = RoomHotspotFallbackDetector();
    // Nothing known yet: nothing to call "off" the hotspot.
    expect(detector.isHotspotRoute('192.168.8.155'), isTrue);
    detector.seed('10.14.189.134');
    expect(detector.isHotspotRoute('10.14.189.134'), isTrue);
    expect(detector.isHotspotRoute('192.168.8.155'), isFalse);
    // Asking does not count towards a fallback.
    expect(detector.observe('10.14.189.134'), isFalse);
  });
}
